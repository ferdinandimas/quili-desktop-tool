using System.Collections.Generic;
using System.Linq;

namespace Quili.Core
{
    public static class VersionCompare
    {
        /// <summary>Whether the release tag (like "v1.4.0") is newer than the running version, comparing the numeric dotted parts.</summary>
        public static bool IsNewer(string tag, string current)
        {
            var a = Parts(tag);
            var b = Parts(current);
            for (int i = 0; i < System.Math.Max(a.Count, b.Count); i++)
            {
                int x = i < a.Count ? a[i] : 0, y = i < b.Count ? b[i] : 0;
                if (x != y) return x > y;
            }
            return false;
        }

        static List<int> Parts(string version)
        {
            var v = version.Trim();
            if (v.StartsWith("v") || v.StartsWith("V")) v = v[1..];
            v = new string(v.TakeWhile(c => char.IsDigit(c) || c == '.').ToArray());
            return v.Split('.', System.StringSplitOptions.RemoveEmptyEntries)
                .Select(p => int.TryParse(p, out var n) ? n : 0).ToList();
        }
    }
}
