using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace AntigravityForCodex
{
    public sealed class WindowsProcess : IDisposable
    {
        private readonly SafeFileHandle job;
        private readonly SafeFileHandle process;

        public int Id { get; }
        public StreamWriter StandardInput { get; }
        public StreamReader StandardOutput { get; }
        public StreamReader StandardError { get; }

        private WindowsProcess(SafeFileHandle job, SafeFileHandle process, int id,
            SafeFileHandle input, SafeFileHandle output, SafeFileHandle error)
        {
            this.job = job;
            this.process = process;
            Id = id;
            var encoding = new UTF8Encoding(false);
            StandardInput = new StreamWriter(new FileStream(input, FileAccess.Write), encoding);
            StandardOutput = new StreamReader(new FileStream(output, FileAccess.Read), encoding);
            StandardError = new StreamReader(new FileStream(error, FileAccess.Read), encoding);
        }

        public static WindowsProcess Start(string executable, string[] arguments, string workspace)
        {
            SafeFileHandle job = null;
            SafeFileHandle process = null;
            SafeFileHandle childInput = null, childOutput = null, childError = null;
            SafeFileHandle input = null, output = null, error = null;
            IntPtr attributes = IntPtr.Zero, inheritedHandles = IntPtr.Zero, jobHandles = IntPtr.Zero;
            bool attributesInitialized = false;
            var information = new ProcessInformation();

            try
            {
                job = CreateJobObjectW(IntPtr.Zero, null);
                if (job.IsInvalid) throw LastError("CreateJobObjectW");
                var limits = new ExtendedLimitInformation();
                limits.Basic.LimitFlags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimitInformation>()))
                    throw LastError("SetInformationJobObject");

                var security = new SecurityAttributes
                {
                    Length = Marshal.SizeOf<SecurityAttributes>(),
                    InheritHandle = true
                };
                if (!CreatePipe(out childInput, out input, ref security, 0) ||
                    !CreatePipe(out output, out childOutput, ref security, 0) ||
                    !CreatePipe(out error, out childError, ref security, 0))
                    throw LastError("CreatePipe");
                foreach (var parentEnd in new[] { input, output, error })
                {
                    if (!SetHandleInformation(parentEnd, 1, 0))
                        throw LastError("SetHandleInformation");
                }

                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
                if (size == IntPtr.Zero) throw LastError("InitializeProcThreadAttributeList");
                attributes = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(attributes, 2, 0, ref size))
                    throw LastError("InitializeProcThreadAttributeList");
                attributesInitialized = true;

                inheritedHandles = Marshal.AllocHGlobal(3 * IntPtr.Size);
                Marshal.WriteIntPtr(inheritedHandles, 0, childInput.DangerousGetHandle());
                Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size, childOutput.DangerousGetHandle());
                Marshal.WriteIntPtr(inheritedHandles, 2 * IntPtr.Size, childError.DangerousGetHandle());
                PutAttribute(attributes, 0x00020002, inheritedHandles, 3 * IntPtr.Size); // HANDLE_LIST
                jobHandles = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobHandles, job.DangerousGetHandle());
                PutAttribute(attributes, 0x0002000D, jobHandles, IntPtr.Size); // JOB_LIST

                var startup = new StartupInfoEx
                {
                    Info = new StartupInfo
                    {
                        Size = Marshal.SizeOf<StartupInfoEx>(),
                        Flags = 0x00000100, // STARTF_USESTDHANDLES
                        Input = childInput.DangerousGetHandle(),
                        Output = childOutput.DangerousGetHandle(),
                        Error = childError.DangerousGetHandle()
                    },
                    Attributes = attributes
                };
                var command = new StringBuilder();
                AppendArgument(command, executable);
                foreach (string argument in arguments)
                {
                    command.Append(' ');
                    AppendArgument(command, argument);
                }

                // Assign the job at creation, before the CLI can launch any descendants.
                const uint extendedStartupInfoPresent = 0x00080000;
                const uint createNoWindow = 0x08000000;
                if (!CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, true,
                    extendedStartupInfoPresent | createNoWindow, IntPtr.Zero, workspace,
                    ref startup, out information))
                    throw LastError("CreateProcessW");
                process = new SafeFileHandle(information.Process, true);
                information.Process = IntPtr.Zero;

                var launched = new WindowsProcess(job, process, information.ProcessId, input, output, error);
                job = process = input = output = error = null; // Ownership is now with launched.
                return launched;
            }
            finally
            {
                job?.Dispose();
                process?.Dispose();
                input?.Dispose();
                output?.Dispose();
                error?.Dispose();
                childInput?.Dispose();
                childOutput?.Dispose();
                childError?.Dispose();
                if (information.Process != IntPtr.Zero) CloseHandle(information.Process);
                if (information.Thread != IntPtr.Zero) CloseHandle(information.Thread);
                if (attributesInitialized) DeleteProcThreadAttributeList(attributes);
                Marshal.FreeHGlobal(attributes);
                Marshal.FreeHGlobal(inheritedHandles);
                Marshal.FreeHGlobal(jobHandles);
            }
        }

        public async Task SendInputAsync(string line)
        {
            try
            {
                if (!string.IsNullOrEmpty(line))
                {
                    await StandardInput.WriteLineAsync(line).ConfigureAwait(false);
                    await StandardInput.FlushAsync().ConfigureAwait(false);
                }
            }
            finally
            {
                StandardInput.BaseStream.Dispose();
            }
        }

        public bool HasExited => WaitForExit(0);

        public bool WaitForExit(int milliseconds)
        {
            uint result = WaitForSingleObject(process, (uint)milliseconds);
            if (result == 0) return true;
            if (result == 258) return false; // WAIT_TIMEOUT
            throw LastError("WaitForSingleObject");
        }

        public int ExitCode
        {
            get
            {
                if (!GetExitCodeProcess(process, out int code)) throw LastError("GetExitCodeProcess");
                return code;
            }
        }

        public void StopTree() => job.Dispose();

        public void Dispose()
        {
            StopTree();
            // Closing stdin without flushing is safe if the child exited before accepting the request.
            StandardInput.BaseStream.Dispose();
            StandardOutput.Dispose();
            StandardError.Dispose();
            process.Dispose();
        }

        public static void ReplaceOpenFile(string source, string target)
        {
            const uint deleteAccess = 0x00010000;
            using (var file = CreateFileW(source, deleteAccess, 7, IntPtr.Zero, 3, 0, IntPtr.Zero))
            {
                if (file.IsInvalid) throw LastError("CreateFileW");
                byte[] name = Encoding.Unicode.GetBytes(target);
                int flagsOffset = Marshal.OffsetOf<RenameInfo>(nameof(RenameInfo.Flags)).ToInt32();
                int rootOffset = Marshal.OffsetOf<RenameInfo>(nameof(RenameInfo.Root)).ToInt32();
                int lengthOffset = Marshal.OffsetOf<RenameInfo>(nameof(RenameInfo.NameLength)).ToInt32();
                int nameOffset = Marshal.OffsetOf<RenameInfo>(nameof(RenameInfo.FirstCharacter)).ToInt32();
                int size = nameOffset + name.Length + sizeof(char);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    const int replaceIfExists = 1;
                    const int posixSemantics = 2; // Readers with delete sharing can retain their old handle.
                    const int fileRenameInfoEx = 22;
                    Marshal.WriteInt32(buffer, flagsOffset, replaceIfExists | posixSemantics);
                    Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                    Marshal.WriteInt32(buffer, lengthOffset, name.Length);
                    Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                    Marshal.WriteInt16(buffer, nameOffset + name.Length, 0);
                    if (!SetFileInformationByHandle(file, fileRenameInfoEx, buffer, size))
                        throw LastError("SetFileInformationByHandle");
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }

        private static void PutAttribute(IntPtr list, int attribute, IntPtr data, int size)
        {
            if (!UpdateProcThreadAttribute(list, 0, (IntPtr)attribute, data, (IntPtr)size, IntPtr.Zero, IntPtr.Zero))
                throw LastError("UpdateProcThreadAttribute");
        }

        private static Win32Exception LastError(string api)
        {
            int error = Marshal.GetLastWin32Error();
            return new Win32Exception(error, api + ": " + new Win32Exception(error).Message);
        }

        // Windows argv quoting, including backslashes immediately before a quote or the end.
        private static void AppendArgument(StringBuilder command, string argument)
        {
            command.Append('"');
            int slashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    slashes++;
                    continue;
                }
                command.Append('\\', character == '"' ? 2 * slashes + 1 : slashes);
                command.Append(character);
                slashes = 0;
            }
            command.Append('\\', 2 * slashes);
            command.Append('"');
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            public int Size;
            public IntPtr Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            public ushort ShowWindow, ReservedSize;
            public IntPtr ReservedPointer, Input, Output, Error;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo Info;
            public IntPtr Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RenameInfo
        {
            public uint Flags;
            public IntPtr Root;
            public uint NameLength;
            public ushort FirstCharacter;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process, Thread;
            public int ProcessId, ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass,
            ref ExtendedLimitInformation information, int length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write,
            ref SecurityAttributes attributes, int size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr attributes, int count, uint flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute,
            IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnedSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributes);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory,
            ref StartupInfoEx startup, out ProcessInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(SafeFileHandle process, out int code);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint sharing,
            IntPtr attributes, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle file, int informationClass,
            IntPtr information, int length);
    }
}
