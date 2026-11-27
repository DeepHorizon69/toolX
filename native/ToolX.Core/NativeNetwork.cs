using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;

namespace ToolX;

public static class NativeNetwork
{
    [DllImport("iphlpapi.dll", SetLastError = true)] private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int tableClass, uint reserved);
    [DllImport("iphlpapi.dll", SetLastError = true)] private static extern uint GetExtendedUdpTable(IntPtr table, ref int size, bool order, int family, int tableClass, uint reserved);
    public static List<Dictionary<string, string>> Listeners()
    {
        var rows = new List<Dictionary<string, string>>();
        foreach (var tcp in new[] { true, false }) foreach (var ipv6 in new[] { false, true })
        {
            var size = 0; var family = ipv6 ? 23 : 2;
            uint Call(IntPtr buffer) => tcp ? GetExtendedTcpTable(buffer, ref size, true, family, 5, 0) : GetExtendedUdpTable(buffer, ref size, true, family, 1, 0);
            var first = Call(IntPtr.Zero); if (first != 122 && first != 0) throw new System.ComponentModel.Win32Exception((int)first);
            var memory = Marshal.AllocHGlobal(size);
            try
            {
                var code = Call(memory); if (code != 0) throw new System.ComponentModel.Win32Exception((int)code);
                var bytes = new byte[size]; Marshal.Copy(memory, bytes, 0, size); var count = BitConverter.ToInt32(bytes, 0); var stride = ipv6 ? (tcp ? 56 : 28) : (tcp ? 24 : 12);
                for (var n = 0; n < count; n++)
                {
                    var offset = 4 + n * stride; if (offset + stride > bytes.Length) throw new InvalidDataException("Invalid network table.");
                    if (tcp && BitConverter.ToUInt32(bytes, offset + (ipv6 ? 48 : 0)) != 2) continue;
                    var addrOffset = offset + (ipv6 ? 0 : tcp ? 4 : 0); var portOffset = offset + (ipv6 ? 20 : tcp ? 8 : 4); var pidOffset = offset + stride - 4;
                    var address = ipv6 ? new IPAddress(bytes.Skip(addrOffset).Take(16).ToArray(), BitConverter.ToUInt32(bytes, offset + 16)) : new IPAddress(bytes.Skip(addrOffset).Take(4).ToArray());
                    var port = (bytes[portOffset] << 8) | bytes[portOffset + 1]; var pid = BitConverter.ToUInt32(bytes, pidOffset); var name = "Unavailable";
                    try { using var process = Process.GetProcessById((int)pid); name = process.ProcessName; } catch (ArgumentException) { } catch (System.ComponentModel.Win32Exception) { }
                    rows.Add(new() { ["_key"] = $"{(tcp ? "TCP" : "UDP")}:{address}:{port}:{pid}", ["Protocol"] = tcp ? "TCP" : "UDP", ["Address"] = address.ToString(), ["Port"] = port.ToString(), ["OwningProcess"] = pid.ToString(), ["ProcessName"] = name });
                    if (rows.Count >= 300) return rows;
                }
            }
            finally { Marshal.FreeHGlobal(memory); }
        }
        return rows;
    }
}
