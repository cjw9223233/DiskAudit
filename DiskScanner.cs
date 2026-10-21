// DiskScanner.cs - read-only disk usage scanner used by Invoke-DiskAudit.ps1
// Target: C# 5 (Windows PowerShell 5.1 Add-Type). No string interpolation / null-conditional.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DiskAudit
{
    public class FileRec
    {
        public string Path;
        public long Disk;
        public long Logical;
        public long MTimeTicks;
        public long ATimeTicks;
        public string Ext;
    }

    public class DirRec
    {
        public string Path;
        public long Disk;
        public long Logical;
        public long Files;
        public int Depth;
    }

    public class DupGroup
    {
        public long Size;
        public string Hash;
        public List<string> Paths = new List<string>();
    }

    public class ScanOptions
    {
        public int Threads = 4;
        public long CollectMinBytes = 10L * 1024 * 1024; // files >= this are kept in the collected list
        public long CutoffTicks = 0;                     // UTC ticks; files older than this count toward OldDisk
        public string NameRegex = null;                  // when set, only matching file names are counted
        public bool Collect = true;                      // record per-directory totals / ext totals / large files
        public int SampleLimit = 200;
    }

    public class DiskScanner
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

        const int OFFLINE = 0x1000;
        const int RECALL_ON_OPEN = 0x40000;
        const int RECALL_ON_DATA_ACCESS = 0x400000;
        const long ONE_MB = 1024 * 1024;

        public ScanOptions Opt;
        public long Files, Dirs, Reparse, CloudPlaceholders, Denied, Errors, ZeroByteFiles, EmptyDirs;
        public long TotalDisk, TotalLogical, OldDisk, OldFiles, CloudLogicalBytes;
        public long HashedBytes, HashPlannedBytes;
        public bool HashTruncated;
        public volatile string Current = "";
        public volatile bool Cancelled;
        public volatile bool Finished;

        public ConcurrentDictionary<string, long[]> DirTotals = new ConcurrentDictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
        public ConcurrentDictionary<string, long[]> ExtTotals = new ConcurrentDictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);

        readonly List<FileRec> collected = new List<FileRec>();
        readonly object collLock = new object();
        readonly List<string> deniedSample = new List<string>();
        readonly List<string> errorSample = new List<string>();
        readonly List<string> emptyDirSample = new List<string>();
        readonly List<string> zeroSample = new List<string>();
        Regex nameRx;

        public DiskScanner(ScanOptions opt)
        {
            Opt = opt ?? new ScanOptions();
            if (!string.IsNullOrEmpty(Opt.NameRegex))
                nameRx = new Regex(Opt.NameRegex, RegexOptions.IgnoreCase | RegexOptions.Compiled);
        }

        // ---------- path helpers ----------
        public static string ToExtended(string p)
        {
            if (string.IsNullOrEmpty(p)) return p;
            if (p.StartsWith(@"\\?\")) return p;
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
            return @"\\?\" + p;
        }

        public static string ToDisplay(string p)
        {
            if (p == null) return p;
            if (p.StartsWith(@"\\?\UNC\")) return @"\\" + p.Substring(8);
            if (p.StartsWith(@"\\?\")) return p.Substring(4);
            return p;
        }

        static string NormalizeRoot(string root)
        {
            string r = root.Trim();
            if (r.Length == 2 && r[1] == ':') r += "\\";
            if (r.Length > 3) r = r.TrimEnd('\\');
            return r;
        }

        // ---------- scanning ----------
        public long[] Run(string root)
        {
            string disp = NormalizeRoot(root);
            string ext = ToExtended(disp);
            long[] r = ScanDir(ext, 0);
            if (Opt.Collect) DirTotals[disp] = r;
            Interlocked.Add(ref TotalDisk, r[0]);
            Interlocked.Add(ref TotalLogical, r[1]);
            return r;
        }

        public Task RunAsync(string[] roots)
        {
            return Task.Factory.StartNew(delegate ()
            {
                try
                {
                    foreach (string r in roots)
                    {
                        if (Cancelled) break;
                        Run(r);
                    }
                }
                finally { Finished = true; }
            }, TaskCreationOptions.LongRunning);
        }

        public void Cancel() { Cancelled = true; }

        void AddSample(List<string> list, string s)
        {
            lock (list) { if (list.Count < Opt.SampleLimit) list.Add(s); }
        }

        long[] ScanDir(string path, int depth)
        {
            long disk = 0, logical = 0, files = 0;
            var subdirs = new List<string>();
            int count = 0;
            Current = path;
            Interlocked.Increment(ref Dirs);

            try
            {
                DirectoryInfo di = new DirectoryInfo(path);
                foreach (FileSystemInfo fsi in di.EnumerateFileSystemInfos())
                {
                    if (Cancelled) break;
                    count++;
                    FileAttributes a = fsi.Attributes;
                    bool isDir = (a & FileAttributes.Directory) != 0;
                    bool reparse = (a & FileAttributes.ReparsePoint) != 0;

                    if (isDir)
                    {
                        if (reparse) { Interlocked.Increment(ref Reparse); continue; }
                        subdirs.Add(fsi.FullName);
                        continue;
                    }

                    if (nameRx != null && !nameRx.IsMatch(fsi.Name)) continue;

                    FileInfo fi = (FileInfo)fsi;
                    long len = 0;
                    try { len = fi.Length; } catch { len = 0; }
                    long fdisk;
                    int ai = (int)a;

                    if ((ai & (OFFLINE | RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS)) != 0)
                    {
                        // cloud placeholder (OneDrive etc.): not stored locally, never trigger a download
                        Interlocked.Increment(ref CloudPlaceholders);
                        Interlocked.Add(ref CloudLogicalBytes, len);
                        Interlocked.Increment(ref Files);
                        files++;
                        continue;
                    }
                    if (reparse)
                    {
                        // app exec links, WSL symlinks, dedup stubs...: take no space of their own
                        Interlocked.Increment(ref Reparse);
                        continue;
                    }

                    if ((a & (FileAttributes.Compressed | FileAttributes.SparseFile)) != 0)
                    {
                        // only compressed/sparse files differ from the logical size; ask the file system for those
                        uint hi;
                        uint lo = GetCompressedFileSizeW(fsi.FullName, out hi);
                        if (lo == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) fdisk = len;
                        else fdisk = ((long)hi << 32) | lo;
                    }
                    else
                    {
                        // estimate: round up to a 4 KB cluster
                        fdisk = (len + 4095) & ~4095L;
                    }

                    disk += fdisk;
                    logical += len;
                    files++;
                    Interlocked.Increment(ref Files);

                    if (len == 0)
                    {
                        Interlocked.Increment(ref ZeroByteFiles);
                        AddSample(zeroSample, ToDisplay(fsi.FullName));
                    }

                    long mt = 0;
                    try { mt = fi.LastWriteTimeUtc.Ticks; } catch { }

                    if (Opt.CutoffTicks > 0 && mt > 0 && mt < Opt.CutoffTicks)
                    {
                        Interlocked.Add(ref OldDisk, fdisk);
                        Interlocked.Increment(ref OldFiles);
                    }

                    if (Opt.Collect)
                    {
                        string e = fi.Extension;
                        if (e == null) e = "";
                        long fd = fdisk;
                        ExtTotals.AddOrUpdate(e,
                            delegate (string k) { return new long[] { fd, 1 }; },
                            delegate (string k, long[] old)
                            {
                                Interlocked.Add(ref old[0], fd);
                                Interlocked.Increment(ref old[1]);
                                return old;
                            });

                        if (fdisk >= Opt.CollectMinBytes || len >= Opt.CollectMinBytes)
                        {
                            long at = 0;
                            try { at = fi.LastAccessTimeUtc.Ticks; } catch { }
                            FileRec fr = new FileRec();
                            fr.Path = ToDisplay(fsi.FullName);
                            fr.Disk = fdisk;
                            fr.Logical = len;
                            fr.MTimeTicks = mt;
                            fr.ATimeTicks = at;
                            fr.Ext = e;
                            lock (collLock) { collected.Add(fr); }
                        }
                    }
                }
            }
            catch (UnauthorizedAccessException)
            {
                Interlocked.Increment(ref Denied);
                AddSample(deniedSample, ToDisplay(path));
            }
            catch (Exception ex)
            {
                Interlocked.Increment(ref Errors);
                AddSample(errorSample, ToDisplay(path) + " :: " + ex.GetType().Name);
            }

            if (count == 0 && !Cancelled)
            {
                Interlocked.Increment(ref EmptyDirs);
                AddSample(emptyDirSample, ToDisplay(path));
            }

            if (subdirs.Count > 0 && !Cancelled)
            {
                if (depth < 3 && Opt.Threads > 1)
                {
                    ParallelOptions po = new ParallelOptions();
                    po.MaxDegreeOfParallelism = Opt.Threads;
                    Parallel.ForEach(subdirs, po, delegate (string d)
                    {
                        long[] r = ScanDir(d, depth + 1);
                        Interlocked.Add(ref disk, r[0]);
                        Interlocked.Add(ref logical, r[1]);
                        Interlocked.Add(ref files, r[2]);
                    });
                }
                else
                {
                    foreach (string d in subdirs)
                    {
                        long[] r = ScanDir(d, depth + 1);
                        disk += r[0];
                        logical += r[1];
                        files += r[2];
                    }
                }
            }

            long[] res = new long[] { disk, logical, files };
            if (Opt.Collect) DirTotals[ToDisplay(path)] = res;
            return res;
        }

        // ---------- results ----------
        public DirRec[] GetDirs(string rootDisplay, int maxDepth)
        {
            string root = NormalizeRoot(rootDisplay);
            string prefix = root.EndsWith("\\") ? root : root + "\\";
            int baseDepth = CountSep(root.TrimEnd('\\'));
            var list = new List<DirRec>();
            foreach (KeyValuePair<string, long[]> kv in DirTotals)
            {
                string k = kv.Key;
                bool isRoot = string.Equals(k, root, StringComparison.OrdinalIgnoreCase);
                if (!isRoot && !k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
                int d = isRoot ? 0 : CountSep(k.TrimEnd('\\')) - baseDepth;
                if (d > maxDepth) continue;
                DirRec r = new DirRec();
                r.Path = k; r.Disk = kv.Value[0]; r.Logical = kv.Value[1]; r.Files = kv.Value[2]; r.Depth = d;
                list.Add(r);
            }
            return list.ToArray();
        }

        static int CountSep(string s)
        {
            int n = 0;
            foreach (char c in s) if (c == '\\') n++;
            return n;
        }

        public long GetDirDisk(string path)
        {
            long[] v;
            if (DirTotals.TryGetValue(NormalizeRoot(path), out v)) return v[0];
            return -1;
        }

        public FileRec[] GetCollected()
        {
            lock (collLock) { return collected.ToArray(); }
        }

        public string[] DeniedSample() { lock (deniedSample) { return deniedSample.ToArray(); } }
        public string[] ErrorSample() { lock (errorSample) { return errorSample.ToArray(); } }
        public string[] EmptyDirSample() { lock (emptyDirSample) { return emptyDirSample.ToArray(); } }
        public string[] ZeroSample() { lock (zeroSample) { return zeroSample.ToArray(); } }

        // Convenience: measure one tree without recording per-directory data.
        // returns { disk, logical, files, oldDisk, oldFiles }
        public static long[] Measure(string path, long cutoffTicks, string nameRegex, int threads)
        {
            ScanOptions o = new ScanOptions();
            o.Collect = false;
            o.Threads = threads;
            o.CutoffTicks = cutoffTicks;
            o.NameRegex = nameRegex;
            DiskScanner s = new DiskScanner(o);
            long[] r;
            if (File.Exists(path))
            {
                FileInfo fi = new FileInfo(path);
                return new long[] { fi.Length, fi.Length, 1, 0, 0 };
            }
            r = s.Run(path);
            return new long[] { r[0], r[1], r[2], s.OldDisk, s.OldFiles };
        }

        // ---------- duplicate detection (read-only; never deletes anything) ----------
        public DupGroup[] FindDuplicates(long minBytes, long maxHashBytes, string[] skipExts, string[] skipPrefixes)
        {
            HashSet<string> skip = new HashSet<string>(skipExts ?? new string[0], StringComparer.OrdinalIgnoreCase);
            string[] prefixes = skipPrefixes ?? new string[0];
            FileRec[] all = GetCollected();
            var sizeGroups = all
                .Where(f => f.Logical >= minBytes && f.Logical > 0 && !skip.Contains(f.Ext ?? "")
                    && !prefixes.Any(p => f.Path.StartsWith(p, StringComparison.OrdinalIgnoreCase)))
                .GroupBy(f => f.Logical)
                .Where(g => g.Count() > 1)
                .OrderByDescending(g => g.Key)
                .ToList();

            // plan within the byte budget (largest groups first, skip ones that would blow the budget)
            var planned = new List<List<FileRec>>();
            long budget = 0;
            foreach (var g in sizeGroups)
            {
                long cost = g.Key * g.Count();
                if (budget + cost > maxHashBytes) { HashTruncated = true; continue; }
                budget += cost;
                planned.Add(g.ToList());
            }
            HashPlannedBytes = budget;

            var result = new ConcurrentBag<DupGroup>();
            ParallelOptions po = new ParallelOptions();
            po.MaxDegreeOfParallelism = Math.Max(1, Math.Min(Opt.Threads, 4));

            Parallel.ForEach(planned, po, delegate (List<FileRec> grp)
            {
                if (Cancelled) return;
                // stage 1: hash of the first 64 KB
                var byPartial = new Dictionary<string, List<FileRec>>();
                foreach (FileRec f in grp)
                {
                    if (Cancelled) return;
                    string h = HashFile(f.Path, 65536);
                    if (h == null) continue;
                    List<FileRec> l;
                    if (!byPartial.TryGetValue(h, out l)) { l = new List<FileRec>(); byPartial[h] = l; }
                    l.Add(f);
                }
                // stage 2: full-file SHA-256 only for those still colliding
                foreach (var kv in byPartial)
                {
                    if (kv.Value.Count < 2) continue;
                    var byFull = new Dictionary<string, List<FileRec>>();
                    foreach (FileRec f in kv.Value)
                    {
                        if (Cancelled) return;
                        string h = HashFile(f.Path, -1);
                        Interlocked.Add(ref HashedBytes, f.Logical);
                        if (h == null) continue;
                        List<FileRec> l;
                        if (!byFull.TryGetValue(h, out l)) { l = new List<FileRec>(); byFull[h] = l; }
                        l.Add(f);
                    }
                    foreach (var fk in byFull)
                    {
                        if (fk.Value.Count < 2) continue;
                        DupGroup dg = new DupGroup();
                        dg.Size = fk.Value[0].Logical;
                        dg.Hash = fk.Key;
                        foreach (FileRec f in fk.Value) dg.Paths.Add(f.Path);
                        result.Add(dg);
                    }
                }
            });

            return result.OrderByDescending(g => g.Size * (g.Paths.Count - 1)).ToArray();
        }

        public Task<DupGroup[]> FindDuplicatesAsync(long minBytes, long maxHashBytes, string[] skipExts, string[] skipPrefixes)
        {
            return Task<DupGroup[]>.Factory.StartNew(delegate ()
            {
                return FindDuplicates(minBytes, maxHashBytes, skipExts, skipPrefixes);
            }, TaskCreationOptions.LongRunning);
        }

        // maxBytes < 0 => whole file
        static string HashFile(string displayPath, long maxBytes)
        {
            try
            {
                string p = displayPath.Length >= 240 ? ToExtended(displayPath) : displayPath;
                using (FileStream fs = new FileStream(p, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete, 1 << 16, FileOptions.SequentialScan))
                using (SHA256 sha = SHA256.Create())
                {
                    byte[] buf = new byte[1 << 16];
                    long remaining = maxBytes < 0 ? long.MaxValue : maxBytes;
                    int n;
                    while (remaining > 0 && (n = fs.Read(buf, 0, (int)Math.Min(buf.Length, remaining))) > 0)
                    {
                        sha.TransformBlock(buf, 0, n, null, 0);
                        remaining -= n;
                    }
                    sha.TransformFinalBlock(new byte[0], 0, 0);
                    return BitConverter.ToString(sha.Hash).Replace("-", "");
                }
            }
            catch { return null; }
        }
    }
}
