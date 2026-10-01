<#
.SYNOPSIS
Runs the read-only Aetheln Unreal content-validation commandlet and verifies its
machine-readable evidence against the exact source, engine, tool, policy, and
runtime-intake inputs used for the scan.
.EXAMPLE
./scripts/content/Invoke-ContentValidation.ps1 `
  -EngineRoot D:/UnrealEngine/UE-5.8.1-source
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidateNotNullOrEmpty()]
	[string] $EngineRoot,
	[string] $OutputPath,
	[ValidateRange(1, 86400)]
	[int] $TimeoutSeconds = 600,
	[ValidateRange(1, 86400)]
	[int] $BuildTimeoutSeconds = 86400,
	[string] $AssetRegistrySnapshotPath,
	[switch] $AllowTestRegistrySnapshot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PinnedEngineTag = '5.8.1-release'
$PinnedEngineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
$ExpectedFamilies = @(
	'collision',
	'rendering_suitability',
	'texture',
	'material',
	'skeletal_animation',
	'map_world',
	'navigation',
	'reference_boundary'
)
$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$JobObjectSource = @"
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Aetheln {
 public static class FileIdentity {
  [StructLayout(LayoutKind.Sequential)] struct ByHandleFileInformation { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime; public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr handle, out ByHandleFileInformation information);
  public static string Get(string path) {
   using(FileStream stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
    ByHandleFileInformation information;
    if(!GetFileInformationByHandle(stream.SafeFileHandle.DangerousGetHandle(),out information)) throw new Win32Exception(Marshal.GetLastWin32Error(),"GetFileInformationByHandle failed.");
    return information.VolumeSerialNumber.ToString("x8")+":"+information.FileIndexHigh.ToString("x8")+information.FileIndexLow.ToString("x8");
   }
  }
 }
 public sealed class OutputGuard : IDisposable {
  const uint ShareRead=0x00000001;
  const int MaxRetainedArtifacts=128;
  const long MaxRetainedBytes=1073741824L;
  const long MaxBuildLogBytes=16777216L;
  const long MaxCommandletLogBytes=16777216L;
  const long MaxReportBytes=16777216L;
  const uint OpenExisting=3;
  const uint GenericRead=0x80000000, GenericWrite=0x40000000, DeleteAccess=0x00010000;
  const uint ReadAttributes=0x00000080;
  const uint HandleFlagInherit=0x00000001;
  const uint AttributeNormal=0x00000080, AttributeDirectory=0x00000010, AttributeReparsePoint=0x00000400;
  const uint FlagBackupSemantics=0x02000000, FlagOpenReparsePoint=0x00200000;
  static readonly IntPtr InvalidHandle=new IntPtr(-1);
  [StructLayout(LayoutKind.Sequential)] struct ByHandleFileInformation { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime; public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow; }
  [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string fileName,uint desiredAccess,uint shareMode,IntPtr securityAttributes,uint creationDisposition,uint flagsAndAttributes,IntPtr templateFile);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr handle,out ByHandleFileInformation information);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFilePointerEx(IntPtr handle,long distance,out long newPosition,uint moveMethod);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetEndOfFile(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteFile(IntPtr handle,byte[] buffer,uint bytesToWrite,out uint bytesWritten,IntPtr overlapped);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool FlushFileBuffers(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(IntPtr handle,int informationClass,IntPtr information,uint size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [StructLayout(LayoutKind.Sequential)] struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }
  [DllImport("ntdll.dll")] static extern int NtSetInformationFile(IntPtr handle,out IoStatusBlock status,IntPtr information,uint length,int informationClass);
  [DllImport("ntdll.dll")] static extern int NtCreateFile(out IntPtr handle,uint access,ref ObjectAttributes attributes,out IoStatusBlock status,IntPtr allocationSize,uint fileAttributes,uint share,uint disposition,uint options,IntPtr eaBuffer,uint eaLength);
  readonly System.Collections.Generic.List<IntPtr> handles=new System.Collections.Generic.List<IntPtr>();
  readonly System.Collections.Generic.Dictionary<string,string> outputIdentities=new System.Collections.Generic.Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
  readonly System.Collections.Generic.Dictionary<string,IntPtr> directoryHandles=new System.Collections.Generic.Dictionary<string,IntPtr>(StringComparer.OrdinalIgnoreCase);
  readonly System.Collections.Generic.HashSet<string> retainedPaths=new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
  readonly System.Collections.Generic.List<string> retainedIdentities=new System.Collections.Generic.List<string>();
  readonly string boundaryRoot;
  long retainedArtifactBytes;
  static string Identity(IntPtr handle,out uint attributes) {
   ByHandleFileInformation information;
   if(!GetFileInformationByHandle(handle,out information)) throw new Win32Exception(Marshal.GetLastWin32Error(),"GetFileInformationByHandle failed for retained output boundary.");
   attributes=information.Attributes;
   return information.VolumeSerialNumber.ToString("x8")+":"+information.FileIndexHigh.ToString("x8")+information.FileIndexLow.ToString("x8");
  }
  public static void EnsureDirectory(string root,string target,string[] protectedIdentityValues) {
   string boundary=Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
   string destination=Path.GetFullPath(target).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
   if(!destination.StartsWith(boundary+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("output_guard_directory_outside_boundary");
   var protectedIdentities=new System.Collections.Generic.HashSet<string>(protectedIdentityValues,StringComparer.Ordinal);
   var held=new System.Collections.Generic.List<IntPtr>();
   try {
    string cursor=boundary;
    IntPtr handle=CreateFile(cursor,ReadAttributes,ShareRead,IntPtr.Zero,OpenExisting,FlagBackupSemantics|FlagOpenReparsePoint,IntPtr.Zero);
    if(handle==InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_directory_root_open_failed: "+cursor);
    held.Add(handle);
    uint attributes; string identity=Identity(handle,out attributes);
    if((attributes&(AttributeDirectory|AttributeReparsePoint))!=AttributeDirectory||protectedIdentities.Contains(identity)) throw new InvalidOperationException("output_guard_directory_root_invalid: "+cursor);
    foreach(string segment in destination.Substring(boundary.Length+1).Split(Path.DirectorySeparatorChar)) {
     if(String.IsNullOrEmpty(segment)||segment=="."||segment=="..") throw new InvalidOperationException("output_guard_directory_segment_invalid");
     cursor=Path.Combine(cursor,segment);
     handle=CreateFile(cursor,ReadAttributes,ShareRead,IntPtr.Zero,OpenExisting,FlagBackupSemantics|FlagOpenReparsePoint,IntPtr.Zero);
     if(handle==InvalidHandle) {
      int error=Marshal.GetLastWin32Error();
      if(error==2||error==3) throw new DirectoryNotFoundException("output_guard_directory_missing: "+cursor);
      throw new Win32Exception(error,"output_guard_directory_open_failed: "+cursor);
     }
     held.Add(handle);
     identity=Identity(handle,out attributes);
     if((attributes&(AttributeDirectory|AttributeReparsePoint))!=AttributeDirectory||protectedIdentities.Contains(identity)) throw new InvalidOperationException("output_path_reparse or alias during guarded directory validation: "+cursor);
    }
   }
   finally { for(int index=held.Count-1;index>=0;--index) CloseHandle(held[index]); }
  }
  void RetainDirectory(string path,System.Collections.Generic.HashSet<string> protectedIdentities) {
   string full=Path.GetFullPath(path);
   if(!retainedPaths.Add(full)) return;
   IntPtr handle=CreateFile(full,ReadAttributes,ShareRead,IntPtr.Zero,OpenExisting,FlagBackupSemantics|FlagOpenReparsePoint,IntPtr.Zero);
   if(handle==InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_directory_open_failed: "+full);
   handles.Add(handle); directoryHandles.Add(full,handle);
   uint attributes; string identity=Identity(handle,out attributes);
   if((attributes&(AttributeDirectory|AttributeReparsePoint))!=AttributeDirectory) throw new InvalidOperationException("output_path_reparse during retained output setup: "+full);
   if(protectedIdentities.Contains(identity)) throw new InvalidOperationException("output_path_alias during retained output setup: "+full);
   retainedIdentities.Add(identity);
  }
  void RetainAncestors(string outputPath,System.Collections.Generic.HashSet<string> protectedIdentities) {
   var paths=new System.Collections.Generic.List<string>();
   DirectoryInfo cursor=new DirectoryInfo(Path.GetDirectoryName(outputPath));
   bool reachedBoundary=false;
   while(cursor!=null) {
    paths.Add(cursor.FullName);
    if(String.Equals(cursor.FullName,boundaryRoot,StringComparison.OrdinalIgnoreCase)) { reachedBoundary=true; break; }
    cursor=cursor.Parent;
   }
   if(!reachedBoundary) throw new InvalidOperationException("output_guard_path_outside_boundary");
   paths.Reverse();
   foreach(string path in paths) RetainDirectory(path,protectedIdentities);
  }
  IntPtr OpenRelativeFile(string path,bool create,uint shareAccess=ShareRead,uint disposition=0) {
   string full=Path.GetFullPath(path), parent=Path.GetDirectoryName(full), name=Path.GetFileName(full);
   if(String.IsNullOrEmpty(name)||name=="."||name=="..") throw new InvalidOperationException("output_guard_relative_name_invalid");
   IntPtr directory;
   if(!directoryHandles.TryGetValue(parent,out directory)) throw new InvalidOperationException("output_guard_relative_parent_not_retained");
   IntPtr nameBuffer=Marshal.StringToHGlobalUni(name), unicodeBuffer=IntPtr.Zero;
   try {
    UnicodeString unicode=new UnicodeString(); unicode.Length=(ushort)(name.Length*2); unicode.MaximumLength=(ushort)((name.Length+1)*2); unicode.Buffer=nameBuffer;
    unicodeBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
    Marshal.StructureToPtr(unicode,unicodeBuffer,false);
    ObjectAttributes attributes=new ObjectAttributes(); attributes.Length=Marshal.SizeOf(typeof(ObjectAttributes)); attributes.RootDirectory=directory; attributes.ObjectName=unicodeBuffer; attributes.Attributes=0x1000; // OBJ_DONT_REPARSE
    IntPtr opened; IoStatusBlock status;
    int result=NtCreateFile(out opened,GenericRead|0x00100000U|(create?GenericWrite|DeleteAccess:0),ref attributes,out status,IntPtr.Zero,AttributeNormal,shareAccess,disposition==0?(create?2U:1U):disposition,create?0x60U:0x00200060U,IntPtr.Zero,0); // SYNCHRONIZE, FILE_NON_DIRECTORY_FILE, synchronous I/O; no-follow on existing files
    if(disposition==3&&result==unchecked((int)0xC0000043)) throw new InvalidOperationException("output_guard_directory_busy: "+parent);
    if(!create&&(result==unchecked((int)0xC0000034)||result==unchecked((int)0xC000003A))) return InvalidHandle;
    if(result!=0) throw new IOException("output_guard_relative_"+(create?"create":"open")+"_failed: NTSTATUS 0x"+result.ToString("X8")+": "+full);
    return opened;
   }
   finally { if(unicodeBuffer!=IntPtr.Zero) Marshal.FreeHGlobal(unicodeBuffer); Marshal.FreeHGlobal(nameBuffer); }
  }
  void CreateOutput(string path,System.Collections.Generic.HashSet<string> protectedIdentities,System.Collections.Generic.HashSet<string> uniqueOutputs) {
   string full=Path.GetFullPath(path);
   RetainAncestors(full,protectedIdentities);
   IntPtr handle=OpenRelativeFile(full,true);
   handles.Add(handle);
   uint attributes; string identity=Identity(handle,out attributes);
   if((attributes&AttributeReparsePoint)!=0) throw new InvalidOperationException("output_path_reparse during retained output setup: "+full);
   if(protectedIdentities.Contains(identity)||!uniqueOutputs.Add(identity)) throw new InvalidOperationException("output_path_alias during retained output setup: "+full);
   retainedIdentities.Add(identity); outputIdentities.Add(full,identity);
  }
  static bool IsRetainedArtifact(string name) {
   return System.Text.RegularExpressions.Regex.IsMatch(name,@"^\.(?:(?:content-validation-report|content-validation|editor-build)\.[0-9a-f]{32}\.pending|previous\.[0-9a-f]{32}\.(?:content-validation-report\.json|content-validation\.log|editor-build\.log))$",System.Text.RegularExpressions.RegexOptions.CultureInvariant);
  }
  void AssertRetentionBudget(string directory) {
   IntPtr retained;
   if(!directoryHandles.TryGetValue(directory,out retained)) throw new InvalidOperationException("output_guard_retention_parent_not_retained");
   uint directoryAttributes; Identity(retained,out directoryAttributes);
   if((directoryAttributes&(AttributeDirectory|AttributeReparsePoint))!=AttributeDirectory) throw new InvalidOperationException("output_path_reparse during retention admission: "+directory);
   int count=0; long bytes=0;
   foreach(string path in Directory.EnumerateFiles(directory)) {
    if(!IsRetainedArtifact(Path.GetFileName(path))) continue;
    FileAttributes attributes=File.GetAttributes(path);
    if((attributes&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("output_guard_retained_artifact_reparse: "+path);
    FileInfo item=new FileInfo(path);
    count++;
    if(item.Length>MaxRetainedBytes-bytes) throw new InvalidOperationException("output_guard_retention_budget_exceeded: "+directory);
    bytes+=item.Length;
    if(count>MaxRetainedArtifacts-6) throw new InvalidOperationException("output_guard_retention_budget_exceeded: "+directory);
   }
   Identity(retained,out directoryAttributes);
   if((directoryAttributes&(AttributeDirectory|AttributeReparsePoint))!=AttributeDirectory) throw new InvalidOperationException("output_path_reparse during retention admission: "+directory);
   retainedArtifactBytes=bytes;
  }
  void AcquireDirectoryLock(string directory,System.Collections.Generic.HashSet<string> protectedIdentities) {
   IntPtr selected=OpenRelativeFile(Path.Combine(directory,".content-validation.output.lock"),true,0,3); // FILE_OPEN_IF, no sharing; stale file is harmless after its handle closes.
   handles.Add(selected);
   uint attributes; string identity=Identity(selected,out attributes);
   if((attributes&AttributeReparsePoint)!=0||protectedIdentities.Contains(identity)) throw new InvalidOperationException("output_guard_directory_lock_alias: "+directory);
  }
  public long AssertPublicationBudget(string[] pendingPaths,string[] finalPaths,string[] protectedIdentityValues) {
   var protectedIdentities=new System.Collections.Generic.HashSet<string>(protectedIdentityValues,StringComparer.Ordinal);
   long available=MaxRetainedBytes-retainedArtifactBytes;
   foreach(string pending in pendingPaths) {
    long length=GetLength(pending);
    if(length>available) throw new InvalidOperationException("output_guard_retention_budget_exceeded: pending output " + pending);
    available-=length;
   }
   long backupBudget=available;
   foreach(string final in finalPaths) {
    IntPtr previous=OpenRelativeFile(final,false);
    if(previous==InvalidHandle) continue;
    try {
     uint attributes; string identity=Identity(previous,out attributes);
     if((attributes&AttributeReparsePoint)!=0||protectedIdentities.Contains(identity)) throw new InvalidOperationException("output_guard_backup_alias_or_reparse: "+final);
     using(SafeFileHandle safe=new SafeFileHandle(previous,false))
     using(FileStream stream=new FileStream(safe,FileAccess.Read,4096,false)) {
      if(stream.Length>available) throw new InvalidOperationException("output_guard_retention_budget_exceeded: prior output " + final);
      available-=stream.Length;
     }
    }
    finally { CloseHandle(previous); }
   }
   return backupBudget;
  }
  public OutputGuard(string root,string[] paths,string[] protectedIdentityValues) {
   boundaryRoot=Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
   var protectedIdentities=new System.Collections.Generic.HashSet<string>(protectedIdentityValues,StringComparer.Ordinal);
   var uniqueOutputs=new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
   try {
    string outputDirectory=Path.GetDirectoryName(Path.GetFullPath(paths[0]));
    foreach(string path in paths) if(!String.Equals(outputDirectory,Path.GetDirectoryName(Path.GetFullPath(path)),StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("output_guard_multiple_directories_unsupported");
    RetainAncestors(paths[0],protectedIdentities);
    AcquireDirectoryLock(outputDirectory,protectedIdentities);
    AssertRetentionBudget(outputDirectory);
    foreach(string path in paths) CreateOutput(path,protectedIdentities,uniqueOutputs);
   }
   catch { Dispose(); throw; }
  }
  public string GetIdentity(string path) {
   string identity;
   if(!outputIdentities.TryGetValue(Path.GetFullPath(path),out identity)) throw new InvalidOperationException("output_guard_path_not_retained");
   return identity;
  }
  IntPtr FindOutputHandle(string path) {
   string expected=GetIdentity(path);
   foreach(IntPtr handle in handles) { uint attributes; if(Identity(handle,out attributes)==expected) return handle; }
   throw new InvalidOperationException("output_guard_handle_not_retained");
  }
  public long GetHandle(string path) {
   return FindOutputHandle(path).ToInt64();
  }
  public void SetInheritable(string path,bool inheritable) {
   if(!SetHandleInformation(FindOutputHandle(path),HandleFlagInherit,inheritable?HandleFlagInherit:0)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_inheritance_update_failed");
  }
  public void WriteUtf8(string path,string value) {
   IntPtr selected=FindOutputHandle(path);
   long position;
   if(!SetFilePointerEx(selected,0,out position,0)||!SetEndOfFile(selected)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_truncate_failed");
   byte[] bytes=new UTF8Encoding(false).GetBytes(value??String.Empty); uint written;
   if(bytes.Length>0&&(!WriteFile(selected,bytes,(uint)bytes.Length,out written,IntPtr.Zero)||written!=(uint)bytes.Length)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_write_failed");
   if(!FlushFileBuffers(selected)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_flush_failed");
  }
  public int RunCapturedBuild(string commandLine,string workingDirectory,string path,int timeoutSeconds,bool allowTestFault) {
   IntPtr selected=FindOutputHandle(path);
   long position;
   if(!SetFilePointerEx(selected,0,out position,0)||!SetEndOfFile(selected)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_truncate_failed");
   string shell=Path.Combine(Environment.SystemDirectory,"cmd.exe");
   using(AnonymousPipeServerStream pipe=new AnonymousPipeServerStream(PipeDirection.In,HandleInheritability.Inheritable))
   using(ContentValidationJob job=new ContentValidationJob()) {
    Process process=null; Task drain=null;
    object gate=new object(); long count=0; bool overflow=false; Exception pumpError=null; bool sawEof=false;
    bool injectPumpFault=allowTestFault&&String.Equals(Environment.GetEnvironmentVariable("AETHELN_CONTENT_TEST_BUILD_PUMP_FAULT"),"1",StringComparison.Ordinal);
    try {
     process=job.StartSuspended(shell,commandLine,workingDirectory,pipe.ClientSafePipeHandle.DangerousGetHandle().ToInt64());
     pipe.DisposeLocalCopyOfClientHandle();
     drain=Task.Run(delegate() {
      byte[] buffer=new byte[8192]; int n;
      try {
       while((n=pipe.Read(buffer,0,buffer.Length))>0) {
        lock(gate) {
         if(injectPumpFault&&count>0&&n>=1024) throw new IOException("fixture_capture_pump_fault");
         if(count+n>MaxBuildLogBytes) { overflow=true; continue; }
         uint written;
         if(!WriteFile(selected,buffer,(uint)n,out written,IntPtr.Zero)||written!=(uint)n) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_build_log_write_failed");
         count+=n;
        }
       }
       sawEof=true;
      }
      catch(Exception error) { lock(gate) { if(pumpError==null) pumpError=error; } }
     });
     Stopwatch clock=Stopwatch.StartNew(); string failure=null;
     while(true) {
      lock(gate) {
       if(overflow) failure="build_output_limit_exceeded: captured log reached 16 MiB; see retained pending log "+path;
       else if(pumpError!=null) failure="build_capture_incomplete: "+pumpError.Message;
      }
      if(failure!=null) break;
      if(clock.Elapsed.TotalSeconds>=timeoutSeconds) { failure="build_timeout_exceeded: editor build exceeded "+timeoutSeconds+" seconds (launcherExited="+process.HasExited+", captureCompleted="+drain.IsCompleted+", jobEmpty="+job.IsEmpty()+", capturedBytes="+count+")"; break; }
      if(drain.IsCompleted&&process.HasExited&&job.IsEmpty()) break;
      Thread.Sleep(50);
     }
     if(failure!=null) {
      job.TerminateAndWait(10000);
      bool launcherExited=process.WaitForExit(5000), pumpStopped=drain.Wait(5000);
      if(!launcherExited||!pumpStopped||!job.IsEmpty()) throw new IOException("build_cleanup_unproven after "+failure);
      // A failed reader cannot observe EOF; empty job plus exited launcher proves process cleanup independently.
      if(!sawEof&&pumpError==null) throw new IOException("build_capture_incomplete: pipe did not reach EOF after cleanup");
      if(!FlushFileBuffers(selected)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_build_log_flush_failed");
      throw new IOException(failure);
     }
     drain.Wait();
     if(!sawEof) throw new IOException("build_capture_incomplete: pipe did not reach EOF");
     if(!FlushFileBuffers(selected)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_build_log_flush_failed");
     return process.ExitCode;
    }
    finally {
     if(!job.IsEmpty()) job.TerminateAndWait(10000);
     if(process!=null) process.Dispose();
    }
   }
  }
  public void AssertCurrentOutputBounds(string commandletLog,string report) {
   if(GetLength(commandletLog)>MaxCommandletLogBytes) throw new IOException("commandlet_log_limit_exceeded: 16 MiB");
   if(GetLength(report)>MaxReportBytes) throw new IOException("content_report_limit_exceeded: 16 MiB");
  }
  public long GetLength(string path) {
   using(SafeFileHandle safe=new SafeFileHandle(FindOutputHandle(path),false))
   using(FileStream stream=new FileStream(safe,FileAccess.Read,4096,false)) return stream.Length;
  }
  public string GetSha256(string path) {
   using(SafeFileHandle safe=new SafeFileHandle(FindOutputHandle(path),false))
   using(FileStream stream=new FileStream(safe,FileAccess.Read,65536,false))
   using(System.Security.Cryptography.SHA256 hash=System.Security.Cryptography.SHA256.Create()) { stream.Position=0; return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-","").ToLowerInvariant(); }
  }
  public string ReadUtf8(string path) {
   using(SafeFileHandle safe=new SafeFileHandle(FindOutputHandle(path),false))
   using(FileStream stream=new FileStream(safe,FileAccess.Read,4096,false)) {
    stream.Position=0;
    if(stream.Length>MaxReportBytes) throw new IOException("output_guard_read_limit_exceeded: 16 MiB");
    byte[] bytes=new byte[(int)stream.Length]; int offset=0;
    while(offset<bytes.Length) { int n=stream.Read(bytes,offset,bytes.Length-offset); if(n==0) throw new IOException("output_guard_read_incomplete"); offset+=n; }
    if(stream.ReadByte()!=-1) throw new IOException("output_guard_read_limit_exceeded: output grew during read");
    return new UTF8Encoding(false,true).GetString(bytes);
   }
  }
  public void Release(string path) {
   string full=Path.GetFullPath(path); IntPtr selected=FindOutputHandle(full);
   CloseHandle(selected); handles.Remove(selected); outputIdentities.Remove(full);
  }
  public void DeleteRetained(string path) {
   IntPtr selected=FindOutputHandle(path);
   IntPtr disposition=Marshal.AllocHGlobal(4);
   try {
    Marshal.WriteInt32(disposition,1);
    if(!SetFileInformationByHandle(selected,4,disposition,4)) throw new Win32Exception(Marshal.GetLastWin32Error(),"output_guard_delete_retained_failed: "+path);
   }
   finally { Marshal.FreeHGlobal(disposition); }
   Release(path);
  }
  public bool BackupExisting(string finalPath,string backupPath,string[] protectedIdentityValues,long maxBytes) {
   string final=Path.GetFullPath(finalPath), backup=Path.GetFullPath(backupPath);
   if(!String.Equals(Path.GetDirectoryName(final),Path.GetDirectoryName(backup),StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("output_guard_backup_parent_mismatch");
   if(!directoryHandles.ContainsKey(Path.GetDirectoryName(final))) throw new InvalidOperationException("output_guard_backup_parent_not_retained");
   IntPtr previous=OpenRelativeFile(final,false);
   if(previous==InvalidHandle) return false;
   try {
    uint attributes; string identity=Identity(previous,out attributes);
    if((attributes&AttributeReparsePoint)!=0) throw new InvalidOperationException("output_guard_backup_reparse: "+final);
    var protectedIdentities=new System.Collections.Generic.HashSet<string>(protectedIdentityValues,StringComparer.Ordinal);
    if(protectedIdentities.Contains(identity)) throw new InvalidOperationException("output_guard_backup_alias: "+final);
    using(SafeFileHandle oldSafe=new SafeFileHandle(previous,false))
    using(FileStream oldStream=new FileStream(oldSafe,FileAccess.Read,65536,false)) {
    if(oldStream.Length>maxBytes) throw new InvalidOperationException("output_guard_retention_budget_exceeded: prior output " + final);
    CreateOutput(backup,protectedIdentities,new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal));
    IntPtr target=FindOutputHandle(backup);
    using(SafeFileHandle backupSafe=new SafeFileHandle(target,false))
    using(FileStream backupStream=new FileStream(backupSafe,FileAccess.ReadWrite,65536,false)) {
     oldStream.CopyTo(backupStream); backupStream.Flush(true);
     oldStream.Position=0; backupStream.Position=0;
     using(System.Security.Cryptography.SHA256 oldHash=System.Security.Cryptography.SHA256.Create())
     using(System.Security.Cryptography.SHA256 backupHash=System.Security.Cryptography.SHA256.Create()) {
      byte[] original=oldHash.ComputeHash(oldStream), copied=backupHash.ComputeHash(backupStream);
      for(int index=0;index<original.Length;++index) if(original[index]!=copied[index]) throw new IOException("output_guard_backup_hash_mismatch: "+final);
     }
    }
    }
    return true;
   }
   finally { CloseHandle(previous); }
  }
  public void Publish(string pendingPath,string finalPath) {
   string pending=Path.GetFullPath(pendingPath), final=Path.GetFullPath(finalPath);
   string parent=Path.GetDirectoryName(pending);
   if(!String.Equals(parent,Path.GetDirectoryName(final),StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("output_guard_publish_parent_mismatch");
   string name=Path.GetFileName(final);
   if(String.IsNullOrEmpty(name)||name=="."||name=="..") throw new InvalidOperationException("output_guard_publish_name_invalid");
   IntPtr directory;
   if(!directoryHandles.TryGetValue(parent,out directory)) throw new InvalidOperationException("output_guard_publish_parent_not_retained");
   uint attributes;
   Identity(directory,out attributes);
   if((attributes&AttributeReparsePoint)!=0) throw new InvalidOperationException("output_guard_publish_parent_reparse");
   IntPtr selected=FindOutputHandle(pending);
   byte[] nameBytes=Encoding.Unicode.GetBytes(name);
   int rootOffset=IntPtr.Size, lengthOffset=rootOffset+IntPtr.Size, nameOffset=lengthOffset+4;
   int size=nameOffset+nameBytes.Length+2;
   IntPtr buffer=Marshal.AllocHGlobal(size);
   try {
    for(int index=0;index<size;++index) Marshal.WriteByte(buffer,index,0);
    Marshal.WriteByte(buffer,0,1); // ReplaceIfExists; never truncate the previous file.
    Marshal.WriteIntPtr(buffer,rootOffset,directory);
    Marshal.WriteInt32(buffer,lengthOffset,nameBytes.Length);
    Marshal.Copy(nameBytes,0,IntPtr.Add(buffer,nameOffset),nameBytes.Length);
    IoStatusBlock status;
    int result=NtSetInformationFile(selected,out status,buffer,(uint)size,10);
    if(result!=0) throw new IOException("output_guard_publish_rename_failed: NTSTATUS 0x"+result.ToString("X8"));
    string identity=outputIdentities[pending]; outputIdentities.Remove(pending); outputIdentities[final]=identity;
   }
   finally { Marshal.FreeHGlobal(buffer); }
  }
  public void AssertNotProtected(string[] protectedIdentityValues) {
   var protectedIdentities=new System.Collections.Generic.HashSet<string>(protectedIdentityValues,StringComparer.Ordinal);
   foreach(string identity in retainedIdentities) if(protectedIdentities.Contains(identity)) throw new InvalidOperationException("output_path_alias during retained output validation");
  }
  public void Dispose() {
   for(int index=handles.Count-1;index>=0;--index) { CloseHandle(handles[index]); }
   handles.Clear(); GC.SuppressFinalize(this);
  }
  ~OutputGuard() { Dispose(); }
 }
 public sealed class ContentValidationJob : IDisposable {
  const uint KillOnJobClose = 0x00002000;
  const uint CreateSuspended = 0x00000004;
  const uint CreateNoWindow = 0x08000000;
  const uint UseStdHandles = 0x00000100;
  IntPtr handle;
  [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)] struct BasicAccountingInformation { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimitInformation { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimitInformation { public BasicLimitInformation BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo { public uint cb; public string reserved, desktop, title; public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags; public short showWindow, reserved2; public IntPtr reserved2Pointer, standardInput, standardOutput, standardError; }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInformation { public IntPtr process, thread; public uint processId, threadId; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int informationClass,out BasicAccountingInformation information,uint size,out uint returnedSize);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  public ContentValidationJob() {
   handle=CreateJobObject(IntPtr.Zero,null);
   if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateJobObject failed.");
   ExtendedLimitInformation information=new ExtendedLimitInformation();
   information.BasicLimitInformation.LimitFlags=KillOnJobClose;
   if(!SetInformationJobObject(handle,9,ref information,(uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) {
    int error=Marshal.GetLastWin32Error(); CloseHandle(handle); handle=IntPtr.Zero;
    throw new Win32Exception(error,"SetInformationJobObject failed.");
   }
  }
  void Assign(IntPtr process) {
   if(handle==IntPtr.Zero) throw new ObjectDisposedException("ContentValidationJob");
   if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(Marshal.GetLastWin32Error(),"AssignProcessToJobObject failed.");
  }
  public Process StartSuspended(string executable, string commandLine, string workingDirectory, long outputHandle) {
   StartupInfo startup=new StartupInfo(); startup.cb=(uint)Marshal.SizeOf(typeof(StartupInfo)); startup.flags=UseStdHandles; startup.standardInput=new IntPtr(outputHandle); startup.standardOutput=new IntPtr(outputHandle); startup.standardError=new IntPtr(outputHandle);
   ProcessInformation information;
   if(!CreateProcess(executable,new StringBuilder(commandLine),IntPtr.Zero,IntPtr.Zero,true,CreateSuspended|CreateNoWindow,IntPtr.Zero,workingDirectory,ref startup,out information))
    throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateProcess failed.");
   Process managed=null;
   try {
    Assign(information.process);
    managed=Process.GetProcessById((int)information.processId); IntPtr managedHandle=managed.Handle;
    if(ResumeThread(information.thread)==UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(),"ResumeThread failed.");
    return managed;
   } catch { TerminateProcess(information.process,1); if(managed!=null) managed.Dispose(); throw; }
   finally { CloseHandle(information.thread); CloseHandle(information.process); }
  }
  public bool IsEmpty() {
   if(handle==IntPtr.Zero) throw new ObjectDisposedException("ContentValidationJob");
   BasicAccountingInformation information; uint returned;
   if(!QueryInformationJobObject(handle,1,out information,(uint)Marshal.SizeOf(typeof(BasicAccountingInformation)),out returned)) throw new Win32Exception(Marshal.GetLastWin32Error(),"build_job_query_failed");
   return information.ActiveProcesses==0;
  }
  public void TerminateAndWait(int milliseconds) {
   if(handle==IntPtr.Zero) throw new ObjectDisposedException("ContentValidationJob");
   if(!TerminateJobObject(handle,1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"build_job_termination_failed");
   Stopwatch clock=Stopwatch.StartNew();
   while(!IsEmpty()) {
    if(clock.ElapsedMilliseconds>=milliseconds) throw new IOException("build_cleanup_unproven: job did not become empty");
    Thread.Sleep(50);
   }
  }
  public void Dispose() { IntPtr current=handle; handle=IntPtr.Zero; if(current!=IntPtr.Zero) CloseHandle(current); GC.SuppressFinalize(this); }
  ~ContentValidationJob() { Dispose(); }
 }
}
"@

function Resolve-RequiredPath([string] $Name, [string] $Path, [string] $PathType) {
	if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) {
		throw "$Name '$Path' does not exist or is not a $($PathType.ToLowerInvariant())."
	}
	return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-IdentityCommand([string] $File, [string[]] $Arguments, [string] $Description) {
	$Output = @(& $File @Arguments 2>&1)
	if ($LASTEXITCODE -ne 0) {
		throw "$Description failed with exit code $LASTEXITCODE`: $($Output -join [Environment]::NewLine)"
	}
	$Value = ($Output | Out-String).Trim()
	if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Description returned no identity." }
	return $Value
}

function Assert-CleanGitTree([string] $Root, [string] $Description) {
	$Output = @(& git -C $Root status --porcelain=v1 --untracked-files=all 2>&1)
	if ($LASTEXITCODE -ne 0) {
		throw "Could not verify the $Description Git tree: $($Output -join [Environment]::NewLine)"
	}
	$Changes = @($Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
	if ($Changes.Count -gt 0) {
		throw "Content validation requires a clean $Description Git tree but found $($Changes.Count) changed path(s):`n - $($Changes -join "`n - ")"
	}
}

function Get-LowerSha256([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string] $Value) {
	$Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try {
		return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function New-FileState([string] $Path, [string] $Description) {
	$ResolvedPath = Resolve-RequiredPath $Description $Path 'Leaf'
	$File = Get-Item -LiteralPath $ResolvedPath
	if ($File.Length -le 0) { throw "$Description '$ResolvedPath' must have a positive size." }
	return [pscustomobject]@{
		Path = $ResolvedPath
		Description = $Description
		SizeBytes = [int64]$File.Length
		Sha256 = Get-LowerSha256 $ResolvedPath
		FileIdentity = [Aetheln.FileIdentity]::Get($ResolvedPath)
	}
}

function New-GuardedFileState([object] $Guard, [string] $Path, [string] $Description) {
	$SizeBytes = $Guard.GetLength($Path)
	if ($SizeBytes -le 0) { throw "$Description '$Path' must have a positive size." }
	return [pscustomobject]@{
		Path = [IO.Path]::GetFullPath($Path)
		Description = $Description
		SizeBytes = [int64]$SizeBytes
		Sha256 = $Guard.GetSha256($Path)
		FileIdentity = $Guard.GetIdentity($Path)
		Guard = $Guard
	}
}

function New-JsonFileState([string] $Path, [string] $Description, [int64] $MaximumBytes) {
	$ResolvedPath = Resolve-RequiredPath $Description $Path 'Leaf'
	$Bytes = [IO.File]::ReadAllBytes($ResolvedPath)
	if ($Bytes.Length -le 0 -or $Bytes.Length -gt $MaximumBytes) { throw "$Description is empty or exceeds its byte limit." }
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { $Sha256 = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
	$Utf8 = [Text.UTF8Encoding]::new($false, $true)
	try { $Json = $Utf8.GetString($Bytes) | ConvertFrom-Json }
	catch { throw "$Description is not valid bounded UTF-8 JSON: $($_.Exception.Message)" }
	return [pscustomobject]@{
		Path = $ResolvedPath
		Description = $Description
		SizeBytes = [int64]$Bytes.Length
		Sha256 = $Sha256
		FileIdentity = [Aetheln.FileIdentity]::Get($ResolvedPath)
		Json = $Json
	}
}

function Assert-OutputBoundary([string[]] $Paths, [object[]] $ProtectedStates, [string] $Phase) {
	$ProtectedIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($State in $ProtectedStates) { [void]$ProtectedIdentities.Add([string]$State.FileIdentity) }
	$OutputIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($Candidate in $Paths) {
		$FullPath = [IO.Path]::GetFullPath($Candidate)
		$Relative = $FullPath.Substring($RepositoryRoot.TrimEnd('\').Length).TrimStart('\')
		$Cursor = $RepositoryRoot
		foreach ($Segment in $Relative.Split('\')) {
			$Cursor = Join-Path $Cursor $Segment
			if (-not (Test-Path -LiteralPath $Cursor)) { break }
			$Item = Get-Item -LiteralPath $Cursor -Force
			if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "output_path_reparse during $Phase" }
		}
		if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
			$Identity = [Aetheln.FileIdentity]::Get($FullPath)
			if ($ProtectedIdentities.Contains($Identity) -or -not $OutputIdentities.Add($Identity)) { throw "output_path_alias during $Phase" }
		}
	}
}

function Invoke-OutputOpenTestSeam([string] $Phase) {
	$Root = [Environment]::GetEnvironmentVariable('AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_ROOT')
	if ([string]::IsNullOrWhiteSpace($Root)) { return }
	if ([Environment]::GetEnvironmentVariable('AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_PHASE') -cne $Phase) { return }
	$Root = [IO.Path]::GetFullPath($Root)
	if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'output_open_test_seam_invalid' }
	$ReadyPath = Join-Path $Root "$Phase.ready"
	$ContinuePath = Join-Path $Root "$Phase.continue"
	[IO.File]::WriteAllText($ReadyPath, 'ready', [Text.UTF8Encoding]::new($false))
	$Deadline = [DateTime]::UtcNow.AddSeconds(10)
	while (-not (Test-Path -LiteralPath $ContinuePath -PathType Leaf)) {
		if ([DateTime]::UtcNow -ge $Deadline) { throw "output_open_test_seam_timeout:$Phase" }
		Start-Sleep -Milliseconds 10
	}
}

function Assert-FileState([object] $State, [string] $Phase) {
	if (-not (Test-Path -LiteralPath $State.Path -PathType Leaf)) {
		throw "$($State.Description) disappeared during $Phase."
	}
	$IsGuarded = $State.PSObject.Properties.Match('Guard').Count -eq 1 -and $null -ne $State.Guard
	$SizeBytes = if ($IsGuarded) { $State.Guard.GetLength($State.Path) } else { (Get-Item -LiteralPath $State.Path).Length }
	$Sha256 = if ($IsGuarded) { $State.Guard.GetSha256($State.Path) } else { Get-LowerSha256 $State.Path }
	if ([int64]$SizeBytes -ne [int64]$State.SizeBytes -or $Sha256 -cne $State.Sha256) {
		throw "$($State.Description) changed during $Phase."
	}
}

function ConvertTo-RepositoryRelativePath([string] $Path, [string] $Root, [string] $Description) {
	$ResolvedPath = Resolve-RequiredPath $Description $Path 'Leaf'
	$ResolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
	$RootPrefix = $ResolvedRoot + [IO.Path]::DirectorySeparatorChar
	if (-not $ResolvedPath.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
		throw "$Description '$ResolvedPath' is outside repository root '$ResolvedRoot'."
	}
	$RelativePath = $ResolvedPath.Substring($RootPrefix.Length).Replace('\', '/')
	if ($RelativePath -cnotmatch '^[^/\\:]+(?:/[^/\\:]+)*$') {
		throw "$Description '$ResolvedPath' does not produce a canonical repository-relative slash path."
	}
	foreach ($Segment in $RelativePath.Split('/')) {
		if ($Segment -ceq '.' -or $Segment -ceq '..') {
			throw "$Description '$ResolvedPath' does not produce a canonical repository-relative slash path."
		}
	}
	return $RelativePath
}

function Assert-CanonicalRepositoryRelativePath([object] $Value, [string] $Context) {
	Assert-NonBlankString $Value $Context
	$Path = [string]$Value
	if ($Path -cnotmatch '^[^/\\:]+(?:/[^/\\:]+)*$') {
		throw "$Context must be a canonical repository-relative slash path."
	}
	foreach ($Segment in $Path.Split('/')) {
		if ($Segment -ceq '.' -or $Segment -ceq '..') {
			throw "$Context must be a canonical repository-relative slash path."
		}
	}
}

function New-BuildArtifactEvidence([object] $State, [string] $BuildId) {
	if ([string]::IsNullOrWhiteSpace($BuildId)) { throw "$($State.Description) build ID must be nonblank." }
	return [pscustomobject]@{
		State = $State
		Evidence = [ordered]@{
			path = ConvertTo-RepositoryRelativePath $State.Path $RepositoryRoot $State.Description
			size_bytes = [int64]$State.SizeBytes
			sha256 = [string]$State.Sha256
			build_id = $BuildId
		}
	}
}

function Get-EditorBuildToolchain([string] $BuildLogPath, [object] $Guard) {
	$BuildLog = $Guard.ReadUtf8($BuildLogPath)
	$Pattern = '^Using Visual Studio (?<CompilerVersion>[0-9]+(?:\.[0-9]+){2,3}) toolchain \((?<CompilerRoot>.+)\) and Windows (?<ResourceCompilerVersion>[0-9]+(?:\.[0-9]+){3}) SDK \((?<SdkRoot>.+)\)\.\r?$'
	$Matches = [regex]::Matches($BuildLog, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
	if ($Matches.Count -ne 1) {
		throw "Editor build log must contain exactly one complete Visual Studio and Windows SDK toolchain identity; found $($Matches.Count)."
	}
	$Match = $Matches[0]
	$CompilerRoot = [string]$Match.Groups['CompilerRoot'].Value
	$SdkRoot = [string]$Match.Groups['SdkRoot'].Value
	if (-not [IO.Path]::IsPathRooted($CompilerRoot) -or -not [IO.Path]::IsPathRooted($SdkRoot)) {
		throw 'Editor build log toolchain roots must be absolute paths.'
	}
	$CompilerPath = Resolve-RequiredPath 'Compiler derived from Editor build log' (Join-Path $CompilerRoot 'bin\Hostx64\x64\cl.exe') 'Leaf'
	$ResourceCompilerPath = Resolve-RequiredPath 'Resource compiler derived from Editor build log' (Join-Path $SdkRoot ("bin\$($Match.Groups['ResourceCompilerVersion'].Value)\x64\rc.exe")) 'Leaf'
	return [pscustomobject]@{
		CompilerVersion = [string]$Match.Groups['CompilerVersion'].Value
		CompilerPath = $CompilerPath
		ResourceCompilerVersion = [string]$Match.Groups['ResourceCompilerVersion'].Value
		ResourceCompilerPath = $ResourceCompilerPath
	}
}

function Initialize-ContentValidationJobType {
	if ($null -eq ('Aetheln.ContentValidationJob' -as [type])) {
		Add-Type -TypeDefinition $JobObjectSource -Language CSharp
	}
}

function Invoke-BoundedTaskKill([int] $ProcessId) {
	$TaskKill = Get-Command 'taskkill.exe' -ErrorAction SilentlyContinue
	if ($null -eq $TaskKill) { return }
	$Info = New-Object Diagnostics.ProcessStartInfo
	$Info.FileName = $TaskKill.Source
	$Info.Arguments = "/PID $ProcessId /T /F"
	$Info.UseShellExecute = $false
	$Info.CreateNoWindow = $true
	$TaskKillProcess = New-Object Diagnostics.Process
	$TaskKillProcess.StartInfo = $Info
	try {
		if ($TaskKillProcess.Start() -and -not $TaskKillProcess.WaitForExit(5000)) {
			try { $TaskKillProcess.Kill() } catch { }
			try { [void]$TaskKillProcess.WaitForExit(1000) } catch { }
		}
	}
	catch { }
	finally { $TaskKillProcess.Dispose() }
}

function Stop-OwnedProcessTree([Diagnostics.Process] $TargetProcess, $TargetJob) {
	if ($null -ne $TargetJob) { $TargetJob.Dispose() }
	try { [void]$TargetProcess.WaitForExit(5000) } catch { }
	$Alive = $false
	try { $Alive = -not $TargetProcess.HasExited } catch { }
	if ($Alive) {
		Invoke-BoundedTaskKill $TargetProcess.Id
		try { if (-not $TargetProcess.HasExited) { $TargetProcess.Kill() } } catch { }
		try { [void]$TargetProcess.WaitForExit(5000) } catch { }
	}
}

function ConvertTo-WindowsCommandLineArgument([string] $Argument) {
	if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
	$Builder = New-Object Text.StringBuilder
	[void]$Builder.Append('"')
	$Backslashes = 0
	foreach ($Character in $Argument.ToCharArray()) {
		if ($Character -eq '\') {
			$Backslashes++
			continue
		}
		if ($Character -eq '"') {
			[void]$Builder.Append(('\' * (($Backslashes * 2) + 1)))
			[void]$Builder.Append('"')
			$Backslashes = 0
			continue
		}
		if ($Backslashes -gt 0) {
			[void]$Builder.Append(('\' * $Backslashes))
			$Backslashes = 0
		}
		[void]$Builder.Append($Character)
	}
	if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
	[void]$Builder.Append('"')
	return $Builder.ToString()
}

function Get-RequiredProperty([object] $Object, [string] $Name, [string] $Context) {
	if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
		throw "$Context is missing required field '$Name'."
	}
	return $Object.PSObject.Properties[$Name].Value
}

function Assert-ExactPropertySet([object] $Object, [string[]] $Expected, [string] $Context) {
	if ($null -eq $Object) { throw "$Context must be a JSON object." }
	$Actual = @($Object.PSObject.Properties.Name)
	foreach ($Name in $Expected) {
		if ($Actual -cnotcontains $Name) { throw "$Context is missing required field '$Name'." }
	}
	foreach ($Name in $Actual) {
		if ($Expected -cnotcontains $Name) { throw "$Context contains unsupported field '$Name'." }
	}
}

function Assert-ExactStringList([object[]] $Actual, [string[]] $Expected, [string] $Context) {
	$ActualStrings = @($Actual | ForEach-Object { [string]$_ })
	if (($ActualStrings -join [char]0) -cne ($Expected -join [char]0)) {
		throw "$Context does not match the required ordered field contract."
	}
}

function Assert-NonBlankString([object] $Value, [string] $Context) {
	if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
		throw "$Context must be a non-blank string."
	}
}

function Test-JsonInteger([object] $Value) {
	return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] `
		-or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Assert-JsonArray([AllowNull()][AllowEmptyCollection()][object] $Value, [string] $Context) {
	if ($Value -isnot [Array]) { throw "$Context must be a JSON array." }
}

function ConvertFrom-UtcTimestamp([object] $Value, [string] $Context) {
	Assert-NonBlankString $Value $Context
	$Parsed = [DateTimeOffset]::MinValue
	if (-not [DateTimeOffset]::TryParse(
		[string]$Value,
		[Globalization.CultureInfo]::InvariantCulture,
		[Globalization.DateTimeStyles]::RoundtripKind,
		[ref]$Parsed) -or $Parsed.Offset -ne [TimeSpan]::Zero) {
		throw "$Context must be an exact UTC timestamp."
	}
	return $Parsed
}

function Assert-ExecutionBoundary(
	[string] $Phase,
	[string] $SourceRevision,
	[string] $EngineRevision,
	[string] $EngineTagRevision,
	[object[]] $FileStates) {
	$CurrentSourceRevision = Invoke-IdentityCommand 'git' @('-C', $RepositoryRoot, 'rev-parse', 'HEAD') "$Phase repository revision lookup"
	Assert-CleanGitTree $RepositoryRoot "repository at $Phase"
	if ($CurrentSourceRevision -cne $SourceRevision) {
		throw "Repository revision changed during $Phase from '$SourceRevision' to '$CurrentSourceRevision'."
	}
	$CurrentEngineRevision = Invoke-IdentityCommand 'git' @('-C', $ResolvedEngineRoot, 'rev-parse', 'HEAD') "$Phase engine revision lookup"
	$CurrentEngineTagRevision = Invoke-IdentityCommand 'git' @('-C', $ResolvedEngineRoot, 'rev-parse', "refs/tags/$PinnedEngineTag^{commit}") "$Phase pinned engine tag lookup"
	Assert-CleanGitTree $ResolvedEngineRoot "engine at $Phase"
	if ($CurrentEngineRevision -cne $EngineRevision -or $CurrentEngineTagRevision -cne $EngineTagRevision) {
		throw "Engine revision or pinned tag changed during $Phase."
	}
	foreach ($State in $FileStates) {
		Assert-FileState $State $Phase
	}
}

function Assert-BuildArtifactDescriptor([object] $Actual, [object] $Expected, [string] $Context) {
	$Fields = $ArtifactDescriptorFields
	Assert-ExactPropertySet $Actual $Fields $Context
	Assert-CanonicalRepositoryRelativePath $Actual.path "$Context.path"
	if (-not (Test-JsonInteger $Actual.size_bytes) -or [int64]$Actual.size_bytes -le 0) {
		throw "$Context.size_bytes must be a positive integer."
	}
	if ($Actual.sha256 -isnot [string] -or [string]$Actual.sha256 -cnotmatch '^[0-9a-f]{64}$') {
		throw "$Context.sha256 must be a lowercase SHA-256 string."
	}
	Assert-NonBlankString $Actual.build_id "$Context.build_id"
	foreach ($Field in $Fields) {
		if ($Actual.$Field -cne $Expected.$Field) {
			if ($Field -ceq 'build_id') { throw "$Context build ID does not match the exact built file." }
			throw "$Context.$Field does not match the exact built file."
		}
	}
}

function Assert-LoadedProjectModuleDescriptor([object] $Actual, [object] $Expected, [string] $Context) {
	$Fields = $LoadedProjectModuleFields
	Assert-ExactPropertySet $Actual $Fields $Context
	Assert-NonBlankString $Actual.name "$Context.name"
	Assert-CanonicalRepositoryRelativePath $Actual.path "$Context.path"
	if (-not (Test-JsonInteger $Actual.size_bytes) -or [int64]$Actual.size_bytes -le 0) {
		throw "$Context.size_bytes must be a positive integer."
	}
	if ($Actual.sha256 -isnot [string] -or [string]$Actual.sha256 -cnotmatch '^[0-9a-f]{64}$') {
		throw "$Context.sha256 must be a lowercase SHA-256 string."
	}
	Assert-NonBlankString $Actual.build_id "$Context.build_id"
	foreach ($Field in $Fields) {
		if ($Actual.$Field -cne $Expected.$Field) {
			if ($Field -ceq 'build_id') { throw "$Context build ID does not match the exact loaded project module." }
			throw "$Context.$Field does not match the exact loaded project module."
		}
	}
}

if ($AllowTestRegistrySnapshot -and [string]::IsNullOrWhiteSpace($AssetRegistrySnapshotPath)) {
	throw 'AllowTestRegistrySnapshot requires AssetRegistrySnapshotPath.'
}
if (-not [string]::IsNullOrWhiteSpace($AssetRegistrySnapshotPath) -and -not $AllowTestRegistrySnapshot) {
	throw 'AssetRegistrySnapshotPath is test-only and requires explicit -AllowTestRegistrySnapshot authorization.'
}

$ProjectPath = Resolve-RequiredPath 'Aetheln project descriptor' (Join-Path $RepositoryRoot 'AethelnOnline.uproject') 'Leaf'
$PolicyPath = Resolve-RequiredPath 'Asset intake policy' (Join-Path $RepositoryRoot 'Config\ContentValidation\asset-intake-policy.json') 'Leaf'
$IntakePath = Resolve-RequiredPath 'Runtime asset intake registry' (Join-Path $RepositoryRoot 'Config\ContentValidation\runtime-asset-intake.json') 'Leaf'
$ResolvedEngineRoot = Resolve-RequiredPath 'EngineRoot' $EngineRoot 'Container'
$BuildScriptPath = Resolve-RequiredPath 'Pinned Unreal Build.bat' (Join-Path $ResolvedEngineRoot 'Engine\Build\BatchFiles\Build.bat') 'Leaf'
$BuildVersionPath = Resolve-RequiredPath 'Unreal Build.version' (Join-Path $ResolvedEngineRoot 'Engine\Build\Build.version') 'Leaf'
$ResolvedSnapshotPath = $null
if ($AllowTestRegistrySnapshot) {
	$ResolvedSnapshotPath = Resolve-RequiredPath 'AssetRegistrySnapshotPath' $AssetRegistrySnapshotPath 'Leaf'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
	$OutputPath = Join-Path $RepositoryRoot 'TestResults\content-validation-report.json'
}
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
	$OutputPath = Join-Path $RepositoryRoot $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$AllowedOutputRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'TestResults')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$AllowedOutputPrefix = $AllowedOutputRoot + [IO.Path]::DirectorySeparatorChar
if (-not $OutputPath.StartsWith($AllowedOutputPrefix, [StringComparison]::OrdinalIgnoreCase) -or
	[IO.Path]::GetFileName($OutputPath) -cne 'content-validation-report.json') {
	throw "OutputPath must name content-validation-report.json below '$AllowedOutputRoot'."
}
$OutputDirectory = Split-Path -Parent $OutputPath
$LogPath = Join-Path $OutputDirectory 'content-validation.log'
$EditorBuildLogPath = Join-Path $OutputDirectory 'editor-build.log'

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required to bind source and engine identities.' }
Initialize-ContentValidationJobType
$SourceRevision = Invoke-IdentityCommand 'git' @('-C', $RepositoryRoot, 'rev-parse', 'HEAD') 'Repository revision lookup'
if ($SourceRevision -cnotmatch '^[0-9a-f]{40}$') { throw "Repository HEAD '$SourceRevision' is not an exact lowercase commit SHA." }
Assert-CleanGitTree $RepositoryRoot 'repository'

$EngineRevision = Invoke-IdentityCommand 'git' @('-C', $ResolvedEngineRoot, 'rev-parse', 'HEAD') 'Engine revision lookup'
if ($EngineRevision -cne $PinnedEngineRevision) {
	throw "Pinned engine revision mismatch: expected '$PinnedEngineRevision' but found '$EngineRevision'."
}
$EngineTagRevision = Invoke-IdentityCommand 'git' @('-C', $ResolvedEngineRoot, 'rev-parse', "refs/tags/$PinnedEngineTag^{commit}") 'Pinned engine tag lookup'
if ($EngineTagRevision -cne $PinnedEngineRevision) {
	throw "Pinned engine tag '$PinnedEngineTag' resolves to '$EngineTagRevision' instead of '$PinnedEngineRevision'."
}
Assert-CleanGitTree $ResolvedEngineRoot 'engine'

$ProjectState = New-FileState $ProjectPath 'Aetheln project descriptor'
$PolicyState = New-JsonFileState $PolicyPath 'Asset intake policy' (1024 * 1024)
$IntakeState = New-JsonFileState $IntakePath 'Runtime asset intake registry' (8 * 1024 * 1024)
$BuildScriptState = New-FileState $BuildScriptPath 'Pinned Unreal Build.bat'
$BuildVersionState = New-FileState $BuildVersionPath 'Unreal Build.version'
$ImmutableFileStates = @($ProjectState, $PolicyState, $IntakeState, $BuildScriptState, $BuildVersionState)
$SnapshotState = $null
if ($AllowTestRegistrySnapshot) {
	$SnapshotState = New-JsonFileState $ResolvedSnapshotPath 'Asset registry snapshot' (64 * 1024 * 1024)
	$ImmutableFileStates += $SnapshotState
}

try { $BuildVersion = Get-Content -LiteralPath $BuildVersionPath -Raw | ConvertFrom-Json } catch { throw "Unreal Build.version is not valid JSON: $($_.Exception.Message)" }
if ([int]$BuildVersion.MajorVersion -ne 5 -or [int]$BuildVersion.MinorVersion -ne 8 -or [int]$BuildVersion.PatchVersion -ne 1) {
	throw 'Unreal Build.version does not identify pinned UE 5.8.1.'
}
$Policy = $PolicyState.Json
$Intake = $IntakeState.Json
if ($Policy.schema_id -cne 'aetheln.asset-intake-policy' -or [int]$Policy.schema_version -ne 2) { throw 'Asset intake policy has an incompatible schema identity.' }
if ($Intake.schema_id -cne 'aetheln.runtime-asset-intake' -or [int]$Intake.schema_version -ne 1 -or
	$Intake.policy_schema_id -cne 'aetheln.asset-intake-policy' -or [int]$Intake.policy_schema_version -ne 2) {
	throw 'Runtime asset intake registry has an incompatible schema identity or policy binding.'
}
$PolicyFamilies = @($Policy.policy_families | ForEach-Object { [string]$_.id })
if (($PolicyFamilies -join ',') -cne ($ExpectedFamilies -join ',')) { throw 'Asset intake policy family order or membership is incompatible with the editor scanner.' }
$ReportFields = @('schema_id','schema_version','revision','engine_identity','policy_sha256','intake_sha256','execution_provenance','audience','started_utc','finished_utc','command','counts','assets','findings','result')
$FindingFields = @('policy_id','code','asset_path','severity','reason','remediation','evidence_field')
$AssetFields = @('asset_path','stable_id','content_version','audience','lifecycle_state','provenance','lifecycle_evidence','family_results')
$ProvenanceFields = @('author_or_provider','source_record','source_version','license_or_permission_evidence','modifications','generation_metadata_when_applicable','content_sha256','reviewer','approval_state')
$LifecycleFields = @('content_identity','temporary_prototype','runtime_candidate','production_approval')
$ExecutionFields = @('repository_clean','engine_revision','engine_tag','engine_binary_sha256','build_version_sha256','target','platform','configuration','editor_build_command_sha256','editor_build_log_sha256','compiler_version','compiler_sha256','resource_compiler_version','resource_compiler_sha256','target_receipt','module_manifest','loaded_project_modules','project_sha256','policy_sha256','intake_sha256','invocation_sha256','registry_source')
$FamilyResultFields = @('policy_id','applicability','deterministic_status','promotion_status','evidence','check_results')
$CheckResultFields = @('check_id','applicability','deterministic_status','promotion_status','evidence')
$ArtifactDescriptorFields = @('path','size_bytes','sha256','build_id')
$LoadedProjectModuleFields = @('name','path','size_bytes','sha256','build_id')
$LoadedProjectModuleNames = @('GameCore','GameTests')
$CountsFields = @('assets','findings','errors','non_promotion')
$ReportContractFields = @('schema_id','schema_version','required_fields','finding_required_fields','asset_required_fields','provenance_required_fields','lifecycle_evidence_required_fields','execution_provenance_required_fields','family_result_required_fields','check_result_required_fields','artifact_descriptor_required_fields','loaded_project_module_required_fields','loaded_project_module_names','counts_required_fields','allowed_results','allowed_deterministic_statuses','allowed_promotion_statuses','allowed_severities','allowed_registry_sources')
$ReportContract = Get-RequiredProperty $Policy 'report' 'Asset intake policy'
Assert-ExactPropertySet $ReportContract $ReportContractFields 'Asset intake policy report contract'
if ($ReportContract.schema_id -cne 'aetheln.content-validation-report' -or -not (Test-JsonInteger $ReportContract.schema_version) -or [int]$ReportContract.schema_version -ne 2) { throw 'Asset intake policy report contract has an incompatible schema identity.' }
Assert-ExactStringList @($ReportContract.required_fields) $ReportFields 'Report required_fields'
Assert-ExactStringList @($ReportContract.finding_required_fields) $FindingFields 'Report finding_required_fields'
Assert-ExactStringList @($ReportContract.asset_required_fields) $AssetFields 'Report asset_required_fields'
Assert-ExactStringList @($ReportContract.provenance_required_fields) $ProvenanceFields 'Report provenance_required_fields'
Assert-ExactStringList @($ReportContract.lifecycle_evidence_required_fields) $LifecycleFields 'Report lifecycle_evidence_required_fields'
Assert-ExactStringList @($ReportContract.execution_provenance_required_fields) $ExecutionFields 'Report execution_provenance_required_fields'
Assert-ExactStringList @($ReportContract.family_result_required_fields) $FamilyResultFields 'Report family_result_required_fields'
Assert-ExactStringList @($ReportContract.check_result_required_fields) $CheckResultFields 'Report check_result_required_fields'
Assert-ExactStringList @($ReportContract.artifact_descriptor_required_fields) $ArtifactDescriptorFields 'Report artifact_descriptor_required_fields'
Assert-ExactStringList @($ReportContract.loaded_project_module_required_fields) $LoadedProjectModuleFields 'Report loaded_project_module_required_fields'
Assert-ExactStringList @($ReportContract.loaded_project_module_names) $LoadedProjectModuleNames 'Report loaded_project_module_names'
Assert-ExactStringList @($ReportContract.counts_required_fields) $CountsFields 'Report counts_required_fields'
Assert-ExactStringList @($ReportContract.allowed_results) @('passed','failed','non_promotion') 'Report allowed_results'
Assert-ExactStringList @($ReportContract.allowed_deterministic_statuses) @('passed','failed','evidence_unavailable','not_applicable') 'Report allowed_deterministic_statuses'
Assert-ExactStringList @($ReportContract.allowed_promotion_statuses) @('eligible','non_promotion','not_applicable') 'Report allowed_promotion_statuses'
Assert-ExactStringList @($ReportContract.allowed_severities) @('error','non_promotion') 'Report allowed_severities'
Assert-ExactStringList @($ReportContract.allowed_registry_sources) @('live_asset_registry','test_snapshot') 'Report allowed_registry_sources'

$PublishedOutputPath = $OutputPath
$PublishedLogPath = $LogPath
$PublishedEditorBuildLogPath = $EditorBuildLogPath
$PublishedOutputPaths = @($PublishedOutputPath, $PublishedLogPath, $PublishedEditorBuildLogPath)
Assert-OutputBoundary $PublishedOutputPaths $ImmutableFileStates 'preparation'
Invoke-OutputOpenTestSeam 'pre-output-directory-create'
[Aetheln.OutputGuard]::EnsureDirectory($RepositoryRoot, $OutputDirectory, [string[]]@($ImmutableFileStates | ForEach-Object { $_.FileIdentity }))
Assert-OutputBoundary $PublishedOutputPaths $ImmutableFileStates 'post-directory-creation'
Invoke-OutputOpenTestSeam 'pre-output-cleanup'
$PendingId = [guid]::NewGuid().ToString('N')
$OutputPath = Join-Path $OutputDirectory ('.content-validation-report.' + $PendingId + '.pending')
$LogPath = Join-Path $OutputDirectory ('.content-validation.' + $PendingId + '.pending')
$EditorBuildLogPath = Join-Path $OutputDirectory ('.editor-build.' + $PendingId + '.pending')
$OutputPaths = @($OutputPath, $LogPath, $EditorBuildLogPath)
Assert-OutputBoundary $OutputPaths $ImmutableFileStates 'pre-build mutation'
$OutputGuard = [Aetheln.OutputGuard]::new(
	$RepositoryRoot,
	[string[]]$OutputPaths,
	[string[]]@($ImmutableFileStates | ForEach-Object { $_.FileIdentity }))
try {
$null = $OutputGuard.AssertPublicationBudget([string[]]$OutputPaths, [string[]]$PublishedOutputPaths,
	[string[]]@($ImmutableFileStates | ForEach-Object { $_.FileIdentity }))
$ReportFileIdentity = $OutputGuard.GetIdentity($OutputPath)
Invoke-OutputOpenTestSeam 'pre-build-open'

Assert-ExecutionBoundary 'pre-build validation' $SourceRevision $EngineRevision $EngineTagRevision $ImmutableFileStates
$BuildArguments = @('AethelnOnlineEditor','Win64','Development',$ProjectPath,'-WaitMutex','-NoHotReloadFromIDE')
$EditorBuildCommandSha256 = Get-TextSha256 ([string]::Join([char]0, @($BuildScriptPath) + $BuildArguments))
$BuildExitCode = $null
$BuildInvocationError = $null
try {
	$BuildShell = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
	$BuildInner = (ConvertTo-WindowsCommandLineArgument $BuildScriptPath) + ' ' + (($BuildArguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' ')
	$BuildShellCommandLine = (ConvertTo-WindowsCommandLineArgument $BuildShell) + ' /d /s /c "' + $BuildInner + '"'
	$BuildExitCode = $OutputGuard.RunCapturedBuild($BuildShellCommandLine, $RepositoryRoot, $EditorBuildLogPath, $BuildTimeoutSeconds, [bool]$AllowTestRegistrySnapshot)
}
catch {
	$BuildInvocationError = $_
}
Assert-ExecutionBoundary 'the editor build' $SourceRevision $EngineRevision $EngineTagRevision $ImmutableFileStates
if ($null -ne $BuildInvocationError) {
	throw "Editor build invocation failed: $($BuildInvocationError.Exception.Message)"
}
if ($BuildExitCode -ne 0) {
	throw "Editor build failed with exit code $BuildExitCode. See '$EditorBuildLogPath'."
}

$EditorBuildLogState = New-GuardedFileState $OutputGuard $EditorBuildLogPath 'Editor build log'
$EditorBuildLogSha256 = $EditorBuildLogState.Sha256
$Toolchain = Get-EditorBuildToolchain $EditorBuildLogPath $OutputGuard
Assert-FileState $EditorBuildLogState 'toolchain identity capture'
$CompilerState = New-FileState $Toolchain.CompilerPath 'Compiler derived from Editor build log'
$ResourceCompilerState = New-FileState $Toolchain.ResourceCompilerPath 'Resource compiler derived from Editor build log'
$CompilerSha256 = $CompilerState.Sha256
$ResourceCompilerSha256 = $ResourceCompilerState.Sha256

$EditorPath = Resolve-RequiredPath 'UnrealEditor-Cmd.exe produced for validation' (Join-Path $ResolvedEngineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe') 'Leaf'
$EditorState = New-FileState $EditorPath 'UnrealEditor-Cmd.exe'
$EngineBinarySha256 = $EditorState.Sha256
$BuildVersionSha256 = $BuildVersionState.Sha256
$ProjectSha256 = $ProjectState.Sha256
$PolicySha256 = $PolicyState.Sha256
$IntakeSha256 = $IntakeState.Sha256

$TargetReceiptPath = Resolve-RequiredPath 'AethelnOnlineEditor target receipt' (Join-Path $RepositoryRoot 'Binaries\Win64\AethelnOnlineEditor.target') 'Leaf'
$TargetReceiptState = New-FileState $TargetReceiptPath 'AethelnOnlineEditor target receipt'
try { $TargetReceipt = Get-Content -LiteralPath $TargetReceiptPath -Raw | ConvertFrom-Json } catch { throw "AethelnOnlineEditor target receipt is not valid JSON: $($_.Exception.Message)" }
$ReceiptTarget = [string](Get-RequiredProperty $TargetReceipt 'TargetName' 'AethelnOnlineEditor target receipt')
$ReceiptPlatform = [string](Get-RequiredProperty $TargetReceipt 'Platform' 'AethelnOnlineEditor target receipt')
$ReceiptConfiguration = [string](Get-RequiredProperty $TargetReceipt 'Configuration' 'AethelnOnlineEditor target receipt')
$ReceiptTargetType = [string](Get-RequiredProperty $TargetReceipt 'TargetType' 'AethelnOnlineEditor target receipt')
$ReceiptProject = [string](Get-RequiredProperty $TargetReceipt 'Project' 'AethelnOnlineEditor target receipt')
$ReceiptLaunchCmd = [string](Get-RequiredProperty $TargetReceipt 'LaunchCmd' 'AethelnOnlineEditor target receipt')
$ReceiptVersion = Get-RequiredProperty $TargetReceipt 'Version' 'AethelnOnlineEditor target receipt'
$BuildId = [string](Get-RequiredProperty $ReceiptVersion 'BuildId' 'AethelnOnlineEditor target receipt Version')
if ($ReceiptTarget -cne 'AethelnOnlineEditor' -or $ReceiptPlatform -cne 'Win64' -or
	$ReceiptConfiguration -cne 'Development' -or $ReceiptTargetType -cne 'Editor' -or
	$ReceiptLaunchCmd -cne '$(EngineDir)/Binaries/Win64/UnrealEditor-Cmd.exe') {
	throw 'AethelnOnlineEditor target receipt identity does not match the exact Editor target, platform, configuration, type, and launch command.'
}
if ([string]::IsNullOrWhiteSpace($ReceiptProject) -or [IO.Path]::IsPathRooted($ReceiptProject)) {
	throw 'AethelnOnlineEditor target receipt Project must identify the repository project by a relative path.'
}
$ReceiptProjectPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $TargetReceiptPath) $ReceiptProject))
if (-not $ReceiptProjectPath.Equals($ProjectPath, [StringComparison]::OrdinalIgnoreCase)) {
	throw 'AethelnOnlineEditor target receipt Project does not resolve to the exact repository project descriptor.'
}
if ([string]::IsNullOrWhiteSpace($BuildId)) { throw 'AethelnOnlineEditor target receipt build ID must be nonblank.' }
Assert-FileState $TargetReceiptState 'target receipt capture'

$ModuleManifestPath = Resolve-RequiredPath 'AethelnOnlineEditor project module manifest' (Join-Path $RepositoryRoot 'Binaries\Win64\UnrealEditor.modules') 'Leaf'
$ModuleManifestState = New-FileState $ModuleManifestPath 'AethelnOnlineEditor project module manifest'
try { $ModuleManifest = Get-Content -LiteralPath $ModuleManifestPath -Raw | ConvertFrom-Json } catch { throw "AethelnOnlineEditor project module manifest is not valid JSON: $($_.Exception.Message)" }
$ManifestBuildId = [string](Get-RequiredProperty $ModuleManifest 'BuildId' 'AethelnOnlineEditor project module manifest')
$ManifestModules = Get-RequiredProperty $ModuleManifest 'Modules' 'AethelnOnlineEditor project module manifest'
if ([string]::IsNullOrWhiteSpace($ManifestBuildId) -or $ManifestBuildId -cne $BuildId) {
	throw 'Target receipt and project module manifest must share one nonblank build ID.'
}
Assert-FileState $ModuleManifestState 'project module manifest capture'

$TargetReceiptArtifact = New-BuildArtifactEvidence $TargetReceiptState $BuildId
$ModuleManifestArtifact = New-BuildArtifactEvidence $ModuleManifestState $BuildId
$ExpectedLoadedProjectModules = @()
$ProjectModuleStates = @()
foreach ($ModuleName in $LoadedProjectModuleNames) {
	if (@($ManifestModules.PSObject.Properties.Name) -cnotcontains $ModuleName) {
		throw "AethelnOnlineEditor project module manifest Modules is missing exact project module '$ModuleName'."
	}
	$ModuleFileName = [string](Get-RequiredProperty $ManifestModules $ModuleName 'AethelnOnlineEditor project module manifest Modules')
	$ExpectedModuleFileName = "UnrealEditor-$ModuleName.dll"
	if ($ModuleFileName -cne $ExpectedModuleFileName -or [IO.Path]::IsPathRooted($ModuleFileName) -or [IO.Path]::GetFileName($ModuleFileName) -cne $ModuleFileName) {
		throw "AethelnOnlineEditor project module manifest $ModuleName path must be the canonical '$ExpectedModuleFileName' file."
	}
	$ModulePath = Join-Path (Split-Path -Parent $ModuleManifestPath) $ModuleFileName
	$ModuleState = New-FileState $ModulePath "$ModuleName project module"
	$ModuleArtifact = New-BuildArtifactEvidence $ModuleState $BuildId
	$ProjectModuleStates += $ModuleArtifact.State
	$ExpectedLoadedProjectModules += [pscustomobject]([ordered]@{
		name = $ModuleName
		path = $ModuleArtifact.Evidence.path
		size_bytes = [int64]$ModuleArtifact.Evidence.size_bytes
		sha256 = [string]$ModuleArtifact.Evidence.sha256
		build_id = $BuildId
	})
}

$StartedUtc = [DateTime]::UtcNow.ToString('o')
$RegistrySource = if ($AllowTestRegistrySnapshot) { 'test_snapshot' } else { 'live_asset_registry' }
$ReportHandle = $OutputGuard.GetHandle($OutputPath)
$CommandletLogHandle = $OutputGuard.GetHandle($LogPath)
$OutputGuard.SetInheritable($OutputPath, $true)
$OutputGuard.SetInheritable($LogPath, $true)
$ArgumentsToBind = @(
	$ProjectPath,
	'-run=GameTests.AethelnContentValidation',
	"-Report=$OutputPath",
	"-ReportFileIdentity=$ReportFileIdentity",
	"-ReportHandle=$ReportHandle",
	"-Policy=$PolicyPath",
	"-Intake=$IntakePath",
	"-Revision=$SourceRevision",
	"-EngineRevision=$EngineRevision",
	"-EngineTag=$PinnedEngineTag",
	"-EngineBinarySha256=$EngineBinarySha256",
	"-BuildVersionSha256=$BuildVersionSha256",
	'-Target=AethelnOnlineEditor',
	'-Platform=Win64',
	'-Configuration=Development',
	"-EditorBuildCommandSha256=$EditorBuildCommandSha256",
	"-EditorBuildLogSha256=$EditorBuildLogSha256",
	"-CompilerVersion=$($Toolchain.CompilerVersion)",
	"-CompilerSha256=$CompilerSha256",
	"-ResourceCompilerVersion=$($Toolchain.ResourceCompilerVersion)",
	"-ResourceCompilerSha256=$ResourceCompilerSha256",
	"-TargetReceiptPath=$($TargetReceiptArtifact.Evidence.path)",
	"-TargetReceiptSizeBytes=$($TargetReceiptArtifact.Evidence.size_bytes)",
	"-TargetReceiptSha256=$($TargetReceiptArtifact.Evidence.sha256)",
	"-TargetReceiptBuildId=$BuildId",
	"-ModuleManifestPath=$($ModuleManifestArtifact.Evidence.path)",
	"-ModuleManifestSizeBytes=$($ModuleManifestArtifact.Evidence.size_bytes)",
	"-ModuleManifestSha256=$($ModuleManifestArtifact.Evidence.sha256)",
	"-ModuleManifestBuildId=$BuildId",
	"-ProjectSha256=$ProjectSha256",
	"-PolicySha256=$PolicySha256",
	"-IntakeSha256=$IntakeSha256",
	"-StartedUtc=$StartedUtc",
	"-RegistrySource=$RegistrySource"
)
if ($AllowTestRegistrySnapshot) {
	$ArgumentsToBind += "-RegistrySnapshot=$ResolvedSnapshotPath"
	$ArgumentsToBind += "-RegistrySnapshotSha256=$($SnapshotState.Sha256)"
	$ArgumentsToBind += '-AllowTestRegistrySnapshot'
}
$InvocationSha256 = Get-TextSha256 ([string]::Join([char]0, $ArgumentsToBind))
$EditorArguments = @($ArgumentsToBind + "-InvocationSha256=$InvocationSha256" + @('-unattended', '-nop4', '-nullrhi', '-nosplash', '-stdout', '-FullStdOutLogOutput'))

$LaunchFileStates = @($ImmutableFileStates) + @($EditorBuildLogState, $CompilerState, $ResourceCompilerState, $EditorState, $TargetReceiptArtifact.State, $ModuleManifestArtifact.State) + @($ProjectModuleStates)
$OutputProtectedStates = @($ImmutableFileStates) + @($CompilerState, $ResourceCompilerState, $EditorState, $TargetReceiptArtifact.State, $ModuleManifestArtifact.State) + @($ProjectModuleStates)
Assert-OutputBoundary $OutputPaths $OutputProtectedStates 'pre-launch validation'
$OutputGuard.AssertNotProtected([string[]]@($OutputProtectedStates | ForEach-Object { $_.FileIdentity }))
Assert-ExecutionBoundary 'pre-launch validation' $SourceRevision $EngineRevision $EngineTagRevision $LaunchFileStates
Invoke-OutputOpenTestSeam 'pre-editor-open'

$Process = $null
$ProcessJob = $null
$ExitCode = $null
$LaunchError = $null
$CapturedOutput = "See '$LogPath' for the commandlet log."
$CommandLine = ConvertTo-WindowsCommandLineArgument $EditorPath
$CommandLine += ' ' + (($EditorArguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' ')
try {
	$ProcessJob = New-Object Aetheln.ContentValidationJob
	$Process = $ProcessJob.StartSuspended($EditorPath, $CommandLine, $RepositoryRoot, $CommandletLogHandle)
	$CommandletClock = [Diagnostics.Stopwatch]::StartNew()
	while (-not $Process.WaitForExit(100)) {
		if ($OutputGuard.GetLength($LogPath) -gt 16MB -or $OutputGuard.GetLength($OutputPath) -gt 16MB) {
			Stop-OwnedProcessTree $Process $ProcessJob
			throw 'commandlet_output_limit_exceeded: log or report exceeded 16 MiB.'
		}
		if ($CommandletClock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
			Stop-OwnedProcessTree $Process $ProcessJob
			throw "Unreal content-validation commandlet timed out after $TimeoutSeconds seconds."
		}
	}
	$Process.WaitForExit()
	$ExitCode = $Process.ExitCode
}
catch {
	$LaunchError = $_
}
finally {
	if ($null -ne $Process) {
		$Alive = $false
		try { $Alive = -not $Process.HasExited } catch { }
		if ($Alive) { Stop-OwnedProcessTree $Process $ProcessJob }
		elseif ($null -ne $ProcessJob) { $ProcessJob.Dispose() }
		$Process.Dispose()
	}
	elseif ($null -ne $ProcessJob) { $ProcessJob.Dispose() }
}
Assert-ExecutionBoundary 'the commandlet launch' $SourceRevision $EngineRevision $EngineTagRevision $LaunchFileStates
Assert-OutputBoundary $OutputPaths $OutputProtectedStates 'report consumption'
if ($null -ne $LaunchError) { throw $LaunchError }
$OutputGuard.AssertCurrentOutputBounds($LogPath, $OutputPath)
$CommandletOutput = $OutputGuard.ReadUtf8($LogPath)
if (-not [string]::IsNullOrWhiteSpace($CommandletOutput)) {
	$CapturedOutput = $CommandletOutput.Substring(0, [Math]::Min(4096, $CommandletOutput.Length))
	if ($CommandletOutput.Length -gt 4096) { $CapturedOutput += "... [truncated; full pending log: '$LogPath']" }
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputPath).Length -eq 0) {
	if ($ExitCode -ne 0) { throw "Unreal content-validation commandlet exited with exit code $ExitCode and did not produce '$OutputPath'. Output: $CapturedOutput" }
	throw "Unreal content-validation commandlet did not produce '$OutputPath'. Output: $CapturedOutput"
}
$ValidatedReportSha256 = $OutputGuard.GetSha256($OutputPath)
try { $Report = $OutputGuard.ReadUtf8($OutputPath) | ConvertFrom-Json } catch { throw "Content-validation report '$OutputPath' is not valid JSON: $($_.Exception.Message)" }

Assert-ExactPropertySet $Report $ReportFields 'Content-validation report'
Assert-ExactPropertySet $Report.execution_provenance $ExecutionFields 'Content-validation report execution_provenance'
if ($Report.schema_id -cne 'aetheln.content-validation-report' -or -not (Test-JsonInteger $Report.schema_version) -or [int]$Report.schema_version -ne 2) { throw 'Content-validation report has an incompatible schema identity.' }
if ($Report.revision -cne $SourceRevision) { throw "Content-validation report revision '$($Report.revision)' does not match '$SourceRevision'." }
if ($Report.engine_identity -cne "$PinnedEngineTag@$EngineRevision") { throw 'Content-validation report engine_identity does not bind the exact engine tag and revision.' }
if ($Report.policy_sha256 -cne $PolicySha256 -or $Report.execution_provenance.policy_sha256 -cne $PolicySha256) { throw 'Content-validation report policy_sha256 does not match the exact policy bytes.' }
if ($Report.intake_sha256 -cne $IntakeSha256 -or $Report.execution_provenance.intake_sha256 -cne $IntakeSha256) { throw 'Content-validation report intake_sha256 does not match the exact intake bytes.' }
if ($Report.audience -cne 'all') { throw 'Content-validation report audience must be all for a complete runtime intake scan.' }
if ($Report.started_utc -cne $StartedUtc) { throw 'Content-validation report started_utc does not match the launched invocation.' }
$ParsedStart = ConvertFrom-UtcTimestamp $Report.started_utc 'Content-validation report started_utc'
$ParsedFinish = ConvertFrom-UtcTimestamp $Report.finished_utc 'Content-validation report finished_utc'
if ($ParsedFinish -lt $ParsedStart) { throw 'Content-validation report finished_utc precedes started_utc.' }
if ($Report.command -cne "GameTests.AethelnContentValidation invocation_sha256=$InvocationSha256") { throw 'Content-validation report command does not bind the launched invocation.' }
$ExpectedExecution = [ordered]@{
	repository_clean = $true
	engine_revision = $EngineRevision
	engine_tag = $PinnedEngineTag
	engine_binary_sha256 = $EngineBinarySha256
	build_version_sha256 = $BuildVersionSha256
	target = 'AethelnOnlineEditor'
	platform = 'Win64'
	configuration = 'Development'
	editor_build_command_sha256 = $EditorBuildCommandSha256
	editor_build_log_sha256 = $EditorBuildLogSha256
	compiler_version = $Toolchain.CompilerVersion
	compiler_sha256 = $CompilerSha256
	resource_compiler_version = $Toolchain.ResourceCompilerVersion
	resource_compiler_sha256 = $ResourceCompilerSha256
	project_sha256 = $ProjectSha256
	policy_sha256 = $PolicySha256
	intake_sha256 = $IntakeSha256
	invocation_sha256 = $InvocationSha256
	registry_source = $RegistrySource
}
if ($Report.execution_provenance.repository_clean -isnot [bool]) { throw 'Content-validation report execution_provenance.repository_clean must be boolean.' }
foreach ($Entry in $ExpectedExecution.GetEnumerator()) {
	if ($Report.execution_provenance.($Entry.Key) -cne $Entry.Value) {
		throw "Content-validation report execution_provenance.$($Entry.Key) does not match the launched input."
	}
}
Assert-BuildArtifactDescriptor $Report.execution_provenance.target_receipt $TargetReceiptArtifact.Evidence 'Content-validation report execution_provenance.target_receipt'
Assert-BuildArtifactDescriptor $Report.execution_provenance.module_manifest $ModuleManifestArtifact.Evidence 'Content-validation report execution_provenance.module_manifest'
Assert-JsonArray $Report.execution_provenance.loaded_project_modules 'Content-validation report execution_provenance.loaded_project_modules'
$LoadedProjectModules = @($Report.execution_provenance.loaded_project_modules)
if ($LoadedProjectModules.Count -ne $LoadedProjectModuleNames.Count) {
	throw 'Content-validation report execution_provenance.loaded_project_modules must contain exactly GameCore then GameTests.'
}
for ($ModuleIndex = 0; $ModuleIndex -lt $ExpectedLoadedProjectModules.Count; $ModuleIndex++) {
	$ExpectedModule = $ExpectedLoadedProjectModules[$ModuleIndex]
	$ActualModule = $LoadedProjectModules[$ModuleIndex]
	$ActualModuleName = [string](Get-RequiredProperty $ActualModule 'name' "Content-validation report execution_provenance.loaded_project_modules[$ModuleIndex]")
	if ($ActualModuleName -cne $ExpectedModule.name) {
		throw 'Content-validation report execution_provenance.loaded_project_modules must contain exactly GameCore then GameTests.'
	}
	Assert-LoadedProjectModuleDescriptor $ActualModule $ExpectedModule "Content-validation report execution_provenance.loaded_project_modules[$ModuleIndex] $($ExpectedModule.name)"
}
$ReportedBuildIds = @(
	[string]$Report.execution_provenance.target_receipt.build_id,
	[string]$Report.execution_provenance.module_manifest.build_id,
	[string]$LoadedProjectModules[0].build_id,
	[string]$LoadedProjectModules[1].build_id
)
if (@($ReportedBuildIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or @($ReportedBuildIds | Select-Object -Unique).Count -ne 1) {
	throw 'Content-validation report target receipt, module manifest, GameCore, and GameTests must share one nonblank build ID.'
}

Assert-ExactPropertySet $Report.counts $CountsFields 'Content-validation report counts'
foreach ($Field in $CountsFields) {
	if (-not (Test-JsonInteger $Report.counts.$Field) -or [int64]$Report.counts.$Field -lt 0) {
		throw "Content-validation report counts.$Field must be a non-negative integer."
	}
}
$ReportAssets = @($Report.assets)
$ReportFindings = @($Report.findings)
$RegistryAssets = @($Intake.assets)
Assert-JsonArray $Report.assets 'Content-validation report assets'
Assert-JsonArray $Report.findings 'Content-validation report findings'
if ([int]$Report.counts.assets -ne $ReportAssets.Count -or [int]$Report.counts.findings -ne $ReportFindings.Count) { throw 'Content-validation report counts do not match its arrays.' }
if ($ReportAssets.Count -ne $RegistryAssets.Count -or $ReportAssets.Count -ne [int]$Intake.expected_asset_count) { throw 'Content-validation report does not cover the complete runtime intake registry.' }
$RegistryByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($RegistryAsset in $RegistryAssets) {
	if ($RegistryByPath.ContainsKey([string]$RegistryAsset.asset_path)) { throw "Runtime intake registry repeats asset_path '$($RegistryAsset.asset_path)'." }
	$RegistryByPath.Add([string]$RegistryAsset.asset_path, $RegistryAsset)
}
$SourceGroupById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($SourceGroup in @($Intake.source_groups)) {
	if ($SourceGroupById.ContainsKey([string]$SourceGroup.id)) { throw "Runtime intake registry repeats source group '$($SourceGroup.id)'." }
	$SourceGroupById.Add([string]$SourceGroup.id, $SourceGroup)
}
$PolicyFamilyById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($PolicyFamily in @($Policy.policy_families)) {
	if ($PolicyFamilyById.ContainsKey([string]$PolicyFamily.id)) { throw "Asset intake policy repeats family '$($PolicyFamily.id)'." }
	$PolicyFamilyById.Add([string]$PolicyFamily.id, $PolicyFamily)
}
$ReportedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$ReportedStableIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$FamilyRecords = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($Asset in $ReportAssets) {
	Assert-ExactPropertySet $Asset $AssetFields "Content-validation report asset '$($Asset.asset_path)'"
	Assert-NonBlankString $Asset.asset_path 'Content-validation report asset_path'
	if (-not $ReportedPaths.Add([string]$Asset.asset_path)) { throw "Content-validation report repeats asset_path '$($Asset.asset_path)'." }
	$RegistryAsset = $null
	if (-not $RegistryByPath.TryGetValue([string]$Asset.asset_path, [ref]$RegistryAsset)) { throw "Content-validation report contains unregistered asset_path '$($Asset.asset_path)'." }
	if ($Asset.stable_id -cne $RegistryAsset.stable_id -or [int]$Asset.content_version -ne [int]$RegistryAsset.content_version -or $Asset.audience -cne $RegistryAsset.audience -or $Asset.lifecycle_state -cne $RegistryAsset.lifecycle_state) {
		throw "Content-validation report identity or lifecycle for '$($Asset.asset_path)' does not match the runtime intake record."
	}
	if (-not $ReportedStableIds.Add([string]$Asset.stable_id)) { throw "Content-validation report repeats stable_id '$($Asset.stable_id)'." }
	if (-not (Test-JsonInteger $Asset.content_version) -or [int64]$Asset.content_version -lt 1) { throw "Content-validation report asset '$($Asset.asset_path)' has an invalid content_version." }

	$SourceGroup = $null
	if (-not $SourceGroupById.TryGetValue([string]$RegistryAsset.source_group_id, [ref]$SourceGroup)) { throw "Runtime intake asset '$($Asset.asset_path)' names a missing source group." }
	Assert-ExactPropertySet $Asset.provenance $ProvenanceFields "Content-validation report asset '$($Asset.asset_path)' provenance"
	$ExpectedProvenance = [ordered]@{
		author_or_provider = $SourceGroup.author_or_provider
		source_record = $SourceGroup.source_record
		source_version = $SourceGroup.source_version
		license_or_permission_evidence = $SourceGroup.license_or_permission_evidence
		modifications = $SourceGroup.modifications
		generation_metadata_when_applicable = $SourceGroup.generation_metadata_when_applicable
		content_sha256 = $RegistryAsset.content_sha256
		reviewer = $SourceGroup.reviewer
		approval_state = $SourceGroup.approval_state
	}
	foreach ($Entry in $ExpectedProvenance.GetEnumerator()) {
		Assert-NonBlankString $Asset.provenance.($Entry.Key) "Content-validation report asset '$($Asset.asset_path)' provenance.$($Entry.Key)"
		if ($Asset.provenance.($Entry.Key) -cne $Entry.Value) { throw "Content-validation report asset '$($Asset.asset_path)' provenance.$($Entry.Key) does not match the intake registry." }
	}
	if ($Asset.provenance.content_sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Content-validation report asset '$($Asset.asset_path)' has an invalid content hash." }

	Assert-ExactPropertySet $Asset.lifecycle_evidence $LifecycleFields "Content-validation report asset '$($Asset.asset_path)' lifecycle_evidence"
	if (($Asset.lifecycle_evidence | ConvertTo-Json -Compress -Depth 12) -cne ($RegistryAsset.lifecycle_evidence | ConvertTo-Json -Compress -Depth 12)) { throw "Content-validation report asset '$($Asset.asset_path)' lifecycle_evidence does not match the intake registry." }
	$Identity = $Asset.lifecycle_evidence.content_identity
	Assert-ExactPropertySet $Identity @('stable_id','content_version','content_sha256') "Content-validation report asset '$($Asset.asset_path)' lifecycle content identity"
	if ($Identity.stable_id -cne $RegistryAsset.stable_id -or [int]$Identity.content_version -ne [int]$RegistryAsset.content_version -or $Identity.content_sha256 -cne $RegistryAsset.content_sha256) { throw "Content-validation report asset '$($Asset.asset_path)' lifecycle evidence does not bind the exact content identity." }
	$TemporaryEvidence = @($Asset.lifecycle_evidence.temporary_prototype)
	$CandidateEvidence = @($Asset.lifecycle_evidence.runtime_candidate)
	$ProductionEvidence = @($Asset.lifecycle_evidence.production_approval)
	if ($Asset.lifecycle_state -ceq 'temporary_prototype') {
		if ($TemporaryEvidence.Count -ne 1 -or $CandidateEvidence.Count -ne 0 -or $ProductionEvidence.Count -ne 0 -or $SourceGroup.approval_state -cne 'temporary_prototype_only') { throw "Content-validation report asset '$($Asset.asset_path)' has invalid temporary lifecycle evidence." }
		Assert-ExactPropertySet $TemporaryEvidence[0] @('owner','approval_record','recovery_trigger','may_be_runtime_candidate') "Content-validation report temporary evidence"
		foreach ($Field in @('owner','approval_record','recovery_trigger')) { Assert-NonBlankString $TemporaryEvidence[0].$Field "Content-validation report temporary evidence $Field" }
		if ($TemporaryEvidence[0].may_be_runtime_candidate -isnot [bool] -or $TemporaryEvidence[0].may_be_runtime_candidate) { throw "Content-validation report temporary evidence cannot be promotion-capable." }
	}
	else {
		if ($TemporaryEvidence.Count -ne 0 -or $CandidateEvidence.Count -ne 1) { throw "Content-validation report asset '$($Asset.asset_path)' lacks exact runtime-candidate evidence." }
		$Candidate = $CandidateEvidence[0]
		Assert-ExactPropertySet $Candidate @('review_revision','reviewer','approval_record','stable_id','content_version','content_sha256') 'Content-validation report runtime-candidate evidence'
		if ($Candidate.review_revision -cnotmatch '^[0-9a-f]{40}$' -or $Candidate.stable_id -cne $RegistryAsset.stable_id -or [int]$Candidate.content_version -ne [int]$RegistryAsset.content_version -or $Candidate.content_sha256 -cne $RegistryAsset.content_sha256) { throw "Content-validation report runtime-candidate evidence does not bind the exact revision and content identity." }
		if ($Asset.lifecycle_state -ceq 'runtime_candidate' -and ($ProductionEvidence.Count -ne 0 -or $SourceGroup.approval_state -cne 'runtime_candidate_approved')) { throw "Content-validation report runtime-candidate evidence conflicts with source approval." }
		if ($Asset.lifecycle_state -ceq 'production_approved') {
			if ($ProductionEvidence.Count -ne 1 -or $SourceGroup.approval_state -cne 'production_approved') { throw "Content-validation report production evidence is missing or unapproved." }
			$Production = $ProductionEvidence[0]
			Assert-ExactPropertySet $Production @('candidate_review_revision','candidate_approval_record','production_revision','reviewer','approval_record','stable_id','content_version','content_sha256') 'Content-validation report production evidence'
			if ($Production.candidate_review_revision -cne $Candidate.review_revision -or $Production.candidate_approval_record -cne $Candidate.approval_record -or $Production.production_revision -cnotmatch '^[0-9a-f]{40}$' -or $Production.stable_id -cne $RegistryAsset.stable_id -or [int]$Production.content_version -ne [int]$RegistryAsset.content_version -or $Production.content_sha256 -cne $RegistryAsset.content_sha256) { throw "Content-validation report production evidence does not bind the exact candidate approval and content identity." }
		}
	}

	$FamilyResults = @($Asset.family_results)
	if ($FamilyResults.Count -ne $ExpectedFamilies.Count) { throw "Content-validation report asset '$($Asset.asset_path)' does not report every policy family exactly once." }
	foreach ($FamilyResult in $FamilyResults) {
		Assert-ExactPropertySet $FamilyResult $FamilyResultFields "Content-validation report asset '$($Asset.asset_path)' family result"
		foreach ($Field in @('policy_id','applicability','deterministic_status','promotion_status','evidence')) { Assert-NonBlankString $FamilyResult.$Field "Content-validation report asset '$($Asset.asset_path)' family result $Field" }
		if ($ExpectedFamilies -cnotcontains [string]$FamilyResult.policy_id) { throw "Content-validation report asset '$($Asset.asset_path)' names unknown family '$($FamilyResult.policy_id)'." }
		$FamilyKey = [string]$Asset.asset_path + [char]0 + [string]$FamilyResult.policy_id
		if ($FamilyRecords.ContainsKey($FamilyKey)) { throw "Content-validation report asset '$($Asset.asset_path)' repeats family '$($FamilyResult.policy_id)'." }
		if (@('applicable','not_applicable') -cnotcontains [string]$FamilyResult.applicability -or
			@('passed','failed','evidence_unavailable','not_applicable') -cnotcontains [string]$FamilyResult.deterministic_status -or
			@('eligible','non_promotion','not_applicable') -cnotcontains [string]$FamilyResult.promotion_status) {
			throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' has an unsupported applicability or status."
		}

		$PolicyFamily = $null
		if (-not $PolicyFamilyById.TryGetValue([string]$FamilyResult.policy_id, [ref]$PolicyFamily)) { throw "Asset intake policy is missing family '$($FamilyResult.policy_id)'." }
		Assert-JsonArray $PolicyFamily.checks "Asset intake policy family '$($FamilyResult.policy_id)' checks"
		$ExpectedChecks = @($PolicyFamily.checks | ForEach-Object { [string]$_ })
		if ($ExpectedChecks.Count -eq 0 -or @($ExpectedChecks | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or @($ExpectedChecks | Select-Object -Unique).Count -ne $ExpectedChecks.Count) {
			throw "Asset intake policy family '$($FamilyResult.policy_id)' must define unique nonblank checks."
		}
		Assert-JsonArray $FamilyResult.check_results "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' check_results"
		$CheckResults = @($FamilyResult.check_results)
		if ($CheckResults.Count -ne $ExpectedChecks.Count) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' must report every policy check exactly once." }
		$CheckResultsById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
		foreach ($CheckResult in $CheckResults) {
			Assert-ExactPropertySet $CheckResult $CheckResultFields "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' check"
			foreach ($Field in $CheckResultFields) { Assert-NonBlankString $CheckResult.$Field "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' check $Field" }
			$CheckId = [string]$CheckResult.check_id
			if ($ExpectedChecks -cnotcontains $CheckId) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' names unknown check '$CheckId'." }
			if ($CheckResultsById.ContainsKey($CheckId)) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' repeats check '$CheckId'." }
			$CheckResultsById.Add($CheckId, $CheckResult)
			if (@('applicable','not_applicable') -cnotcontains [string]$CheckResult.applicability -or
				@('passed','failed','evidence_unavailable','not_applicable') -cnotcontains [string]$CheckResult.deterministic_status -or
				@('eligible','non_promotion','not_applicable') -cnotcontains [string]$CheckResult.promotion_status) {
				throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' check '$CheckId' has an unsupported applicability or status."
			}
			if ($CheckResult.applicability -ceq 'not_applicable') {
				if ($CheckResult.deterministic_status -cne 'not_applicable' -or $CheckResult.promotion_status -cne 'not_applicable') { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' non-applicable check '$CheckId' must use both not_applicable statuses." }
			}
			elseif ($CheckResult.deterministic_status -ceq 'not_applicable' -or $CheckResult.promotion_status -ceq 'not_applicable') {
				throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' applicable check '$CheckId' cannot use not_applicable statuses."
			}
			if ($CheckResult.deterministic_status -ceq 'evidence_unavailable' -and $CheckResult.promotion_status -cne 'non_promotion') {
				throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' applicable check '$CheckId' with unavailable evidence must be non_promotion."
			}
			if ($CheckResult.deterministic_status -ceq 'failed' -and $CheckResult.promotion_status -cne 'non_promotion') {
				throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' failed check '$CheckId' must be non_promotion."
			}
		}
		foreach ($ExpectedCheck in $ExpectedChecks) {
			if (-not $CheckResultsById.ContainsKey($ExpectedCheck)) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' is missing check '$ExpectedCheck'." }
		}

		$ApplicableChecks = @($CheckResults | Where-Object { $_.applicability -ceq 'applicable' })
		$FailedChecks = @($ApplicableChecks | Where-Object { $_.deterministic_status -ceq 'failed' })
		$UnavailableChecks = @($ApplicableChecks | Where-Object { $_.deterministic_status -ceq 'evidence_unavailable' })
		$BlockedChecks = @($ApplicableChecks | Where-Object { $_.promotion_status -ceq 'non_promotion' })
		$ExpectedApplicability = if ($ApplicableChecks.Count -gt 0) { 'applicable' } else { 'not_applicable' }
		$ExpectedDeterministic = if ($ApplicableChecks.Count -eq 0) { 'not_applicable' } elseif ($FailedChecks.Count -gt 0) { 'failed' } elseif ($UnavailableChecks.Count -gt 0) { 'evidence_unavailable' } else { 'passed' }
		$ExpectedPromotion = if ($ApplicableChecks.Count -eq 0) { 'not_applicable' } elseif ($FailedChecks.Count -gt 0 -or $UnavailableChecks.Count -gt 0 -or $BlockedChecks.Count -gt 0 -or $Asset.lifecycle_state -ceq 'temporary_prototype') { 'non_promotion' } else { 'eligible' }
		if ($FamilyResult.applicability -cne $ExpectedApplicability) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' applicability does not aggregate check results." }
		if ($FamilyResult.deterministic_status -cne $ExpectedDeterministic) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' deterministic_status does not aggregate failed over evidence_unavailable over passed." }
		if ($FamilyResult.promotion_status -cne $ExpectedPromotion) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' promotion_status does not aggregate non_promotion over eligible." }
		if ($Asset.lifecycle_state -cin @('runtime_candidate','production_approved') -and $FamilyResult.policy_id -ceq 'reference_boundary' -and $FamilyResult.applicability -cne 'applicable') { throw "Content-validation report asset '$($Asset.asset_path)' runtime lifecycle requires applicable reference_boundary evidence." }
		if ($FamilyResult.applicability -ceq 'not_applicable') {
			$ExpectedEvidence = "policy:$($FamilyResult.policy_id):not_applicable:no_observed_checks"
			if ($FamilyResult.evidence -cne $ExpectedEvidence) { throw "Content-validation report asset '$($Asset.asset_path)' family '$($FamilyResult.policy_id)' lacks canonical not_applicable evidence." }
		}
		$FamilyRecords.Add($FamilyKey, [pscustomobject]@{
			AssetPath = [string]$Asset.asset_path
			PolicyId = [string]$FamilyResult.policy_id
			Deterministic = [string]$FamilyResult.deterministic_status
			Promotion = [string]$FamilyResult.promotion_status
		})
	}
	foreach ($FamilyId in $ExpectedFamilies) {
		if (-not $FamilyRecords.ContainsKey(([string]$Asset.asset_path + [char]0 + $FamilyId))) { throw "Content-validation report asset '$($Asset.asset_path)' is missing family '$FamilyId'." }
	}
}
$ExpectedPaths = @($RegistryAssets | ForEach-Object { [string]$_.asset_path } | Sort-Object -CaseSensitive)
$ActualPaths = @($ReportAssets | ForEach-Object { [string]$_.asset_path } | Sort-Object -CaseSensitive)
if (($ExpectedPaths -join "`n") -cne ($ActualPaths -join "`n")) { throw 'Content-validation report asset paths do not exactly match the runtime intake registry.' }

foreach ($Finding in $ReportFindings) {
	Assert-ExactPropertySet $Finding $FindingFields 'Content-validation report finding'
	foreach ($Field in $FindingFields) { Assert-NonBlankString $Finding.$Field "Content-validation report finding $Field" }
	if (@('error','non_promotion') -cnotcontains [string]$Finding.severity) { throw "Content-validation report finding severity '$($Finding.severity)' is unsupported." }
	$PolicyFamily = $null
	if (-not $PolicyFamilyById.TryGetValue([string]$Finding.policy_id, [ref]$PolicyFamily)) { throw "Content-validation report finding names unknown family '$($Finding.policy_id)'." }
	$FamilyRecord = $null
	$FamilyKey = [string]$Finding.asset_path + [char]0 + [string]$Finding.policy_id
	if (-not $FamilyRecords.TryGetValue($FamilyKey, [ref]$FamilyRecord)) { throw "Content-validation report finding does not identify one reported asset family." }
	$ExpectedCode = if ($Finding.severity -ceq 'error') { [string]$PolicyFamily.failure_code } else { ([string]$PolicyFamily.failure_code -replace '\.failed$', '.non_promotion') }
	$FindingMatchesFamily = if ($Finding.severity -ceq 'error') {
		$FamilyRecord.Deterministic -ceq 'failed'
	}
	else {
		$FamilyRecord.Deterministic -cne 'failed' -and $FamilyRecord.Promotion -ceq 'non_promotion'
	}
	if ($Finding.code -cne $ExpectedCode -or -not $FindingMatchesFamily) { throw "Content-validation report finding for '$($Finding.asset_path)' family '$($Finding.policy_id)' does not match the policy code and family statuses." }
}
foreach ($FamilyRecord in $FamilyRecords.Values) {
	if ($FamilyRecord.Deterministic -ceq 'failed' -or $FamilyRecord.Promotion -ceq 'non_promotion') {
		$ExpectedSeverity = if ($FamilyRecord.Deterministic -ceq 'failed') { 'error' } else { 'non_promotion' }
		$Matching = @($ReportFindings | Where-Object { $_.asset_path -ceq $FamilyRecord.AssetPath -and $_.policy_id -ceq $FamilyRecord.PolicyId -and $_.severity -ceq $ExpectedSeverity })
		if ($Matching.Count -ne 1) { throw "Content-validation report family '$($FamilyRecord.PolicyId)' blocking statuses require exactly one correlated finding." }
	}
}
$ErrorCount = @($ReportFindings | Where-Object { $_.severity -ceq 'error' }).Count
$NonPromotionCount = @($ReportFindings | Where-Object { $_.severity -ceq 'non_promotion' }).Count
if ([int]$Report.counts.errors -ne $ErrorCount -or [int]$Report.counts.non_promotion -ne $NonPromotionCount) { throw 'Content-validation report severity counts do not match its findings.' }
if (@('passed','failed','non_promotion') -cnotcontains [string]$Report.result) { throw "Content-validation report result '$($Report.result)' is unsupported." }
$HasFailedFamily = @($FamilyRecords.Values | Where-Object { $_.Deterministic -ceq 'failed' }).Count -gt 0
$HasNonPromotionFamily = @($FamilyRecords.Values | Where-Object { $_.Promotion -ceq 'non_promotion' }).Count -gt 0
if (($Report.result -ceq 'passed' -and ($ErrorCount -ne 0 -or $NonPromotionCount -ne 0 -or $HasFailedFamily -or $HasNonPromotionFamily)) -or
	($Report.result -ceq 'failed' -and ($ErrorCount -eq 0 -or -not $HasFailedFamily)) -or
	($Report.result -ceq 'non_promotion' -and ($ErrorCount -ne 0 -or $NonPromotionCount -eq 0 -or -not $HasNonPromotionFamily))) {
	throw 'Content-validation report result is inconsistent with family statuses and findings.'
}
if ($ExitCode -ne 0) { throw "Unreal content-validation commandlet exited with exit code $ExitCode and report result '$($Report.result)'. Output: $CapturedOutput" }
if ($Report.result -ceq 'failed') { throw 'Unreal content-validation commandlet returned exit code zero with a failed report.' }

$PendingOutputHashes = @($OutputPaths | ForEach-Object { $OutputGuard.GetSha256($_) })
if ($PendingOutputHashes[0] -cne $ValidatedReportSha256) { throw 'Content-validation report bytes changed after validation.' }
Assert-ExecutionBoundary 'pre-publication validation' $SourceRevision $EngineRevision $EngineTagRevision $LaunchFileStates
Assert-OutputBoundary $PublishedOutputPaths $OutputProtectedStates 'pre-publication validation'
$PublicationPairs = @(
	@{ Pending = $EditorBuildLogPath; Final = $PublishedEditorBuildLogPath },
	@{ Pending = $LogPath; Final = $PublishedLogPath },
	@{ Pending = $OutputPath; Final = $PublishedOutputPath }
)
$PriorBackups = @{}
$BackupId = [guid]::NewGuid().ToString('N')
$ProtectedOutputIdentities = [string[]]@($OutputProtectedStates | ForEach-Object { $_.FileIdentity })
$RemainingBackupBytes = $OutputGuard.AssertPublicationBudget([string[]]$OutputPaths, [string[]]$PublishedOutputPaths, $ProtectedOutputIdentities)
# Copy each previous entry into a distinct, retained, byte-verified backup.
# No published path changes if backup creation or new-run validation fails.
foreach ($Pair in $PublicationPairs) {
	$Backup = Join-Path $OutputDirectory ('.previous.' + $BackupId + '.' + [IO.Path]::GetFileName($Pair.Final))
	if ($OutputGuard.BackupExisting($Pair.Final, $Backup, $ProtectedOutputIdentities, $RemainingBackupBytes)) {
		$PriorBackups[$Pair.Final] = @{ Path = $Backup; Sha256 = $OutputGuard.GetSha256($Backup) }
		$RemainingBackupBytes -= $OutputGuard.GetLength($Backup)
	}
}
# Publish the report last. If a later rename fails, restore any earlier logs
# from the held backups; if restoration is denied, retain backups for recovery.
$PublishedPairs = [Collections.Generic.List[object]]::new()
try {
	foreach ($Pair in $PublicationPairs) {
		$OutputGuard.Publish($Pair.Pending, $Pair.Final)
		$PublishedPairs.Add($Pair)
		if ($PublishedPairs.Count -eq 1 -and $env:AETHELN_CONTENT_TEST_PUBLISH_FAIL_AFTER_FIRST -ceq '1') {
			throw 'output_publication_test_failure_after_first_rename'
		}
	}
	$PublishedHashes = @($PublishedOutputPaths | ForEach-Object { $OutputGuard.GetSha256($_) })
	for ($Index = 0; $Index -lt $PendingOutputHashes.Count; $Index++) {
		if ($PendingOutputHashes[$Index] -cne $PublishedHashes[$Index]) { throw 'Published content-validation output bytes changed during publication.' }
	}
}
catch {
	$PublicationFailure = $_
	$RecoveryFailures = [Collections.Generic.List[string]]::new()
	for ($Index = $PublishedPairs.Count - 1; $Index -ge 0; $Index--) {
		$Pair = $PublishedPairs[$Index]
		try {
			if ($PriorBackups.ContainsKey($Pair.Final)) {
				$Backup = $PriorBackups[$Pair.Final]
				$OutputGuard.Release($Pair.Final)
				$OutputGuard.Publish($Backup.Path, $Pair.Final)
				if ($OutputGuard.GetSha256($Pair.Final) -cne $Backup.Sha256) { throw 'restored output bytes differ from the retained backup' }
			}
			else { $OutputGuard.DeleteRetained($Pair.Final) }
		}
		catch {
			$BackupDetail = if ($PriorBackups.ContainsKey($Pair.Final)) { "; backup: '$($PriorBackups[$Pair.Final].Path)'" } else { '; no prior file existed' }
			$RecoveryFailures.Add("$($Pair.Final): $($_.Exception.Message)$BackupDetail")
		}
	}
	if ($RecoveryFailures.Count -gt 0) {
		throw "Content-validation output publication failed: $($PublicationFailure.Exception.Message). Manual recovery is required for the exact output(s): $($RecoveryFailures -join '; ')"
	}
	throw "Content-validation output publication failed and prior outputs were restored: $($PublicationFailure.Exception.Message)"
}
Write-Output "Content validation $($Report.result): $($ReportAssets.Count) governed package(s), $($ReportFindings.Count) finding(s). Report: '$PublishedOutputPath'."
}
finally { $OutputGuard.Dispose() }
