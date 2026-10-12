using System;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Windows;
using Docky.Core;

namespace Docky.Services
{
    #region Core Audio interop

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IMMNotificationClient client);
        int UnregisterEndpointNotificationCallback(IMMNotificationClient client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IAudioEndpointVolumeCallback notify);
        int UnregisterControlChangeNotify(IAudioEndpointVolumeCallback notify);
        int GetChannelCount(out uint count);
        int SetMasterVolumeLevel(float level, ref Guid ctx);
        int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
        int GetMasterVolumeLevel(out float level);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channel, float level, ref Guid ctx);
        int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid ctx);
        int GetChannelVolumeLevel(uint channel, out float level);
        int GetChannelVolumeLevelScalar(uint channel, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        int GetVolumeStepInfo(out uint step, out uint count);
        int VolumeStepUp(ref Guid ctx);
        int VolumeStepDown(ref Guid ctx);
        int QueryHardwareSupport(out uint mask);
        int GetVolumeRange(out float min, out float max, out float increment);
    }

    [ComImport, Guid("657804FA-D6AD-4496-8A60-352752AF4F89"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolumeCallback
    {
        [PreserveSig] int OnNotify(IntPtr data);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey { public Guid Format; public int Id; }

    [ComImport, Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMNotificationClient
    {
        [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int newState);
        [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        [PreserveSig] int OnDefaultDeviceChanged(int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string defaultDeviceId);
        [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string deviceId, PropertyKey key);
    }

    #endregion

    /// <summary>System volume: read, set, and listen for changes made anywhere.</summary>
    [ComVisible(true)]
    public sealed class VolumeService : IAudioEndpointVolumeCallback, IMMNotificationClient
    {
        public static VolumeService Shared { get; } = new();

        /// <summary>Raised (on the UI thread) when the volume changes outside Docky.</summary>
        public event Action ExternalChange;

        private IMMDeviceEnumerator enumerator;
        private IAudioEndpointVolume endpoint;
        private Guid context = Guid.NewGuid();

        public void Start()
        {
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
                enumerator.RegisterEndpointNotificationCallback(this);
                Bind();
            }
            catch { endpoint = null; }
        }

        private void Bind()
        {
            try
            {
                if (endpoint != null) endpoint.UnregisterControlChangeNotify(this);
                endpoint = null;
                if (enumerator.GetDefaultAudioEndpoint(0 /* render */, 1 /* multimedia */, out var device) != 0 || device == null) return;
                var iid = typeof(IAudioEndpointVolume).GUID;
                device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out var obj);
                endpoint = (IAudioEndpointVolume)obj;
                endpoint.RegisterControlChangeNotify(this);
            }
            catch { endpoint = null; }
        }

        public bool Available => endpoint != null;

        public double Level
        {
            get { try { endpoint.GetMasterVolumeLevelScalar(out float v); return v; } catch { return 0; } }
        }

        public bool Muted
        {
            get { try { endpoint.GetMute(out bool m); return m; } catch { return false; } }
        }

        public void SetLevel(double level)
        {
            if (endpoint == null) return;
            float v = (float)Math.Clamp(level, 0, 1);
            endpoint.SetMasterVolumeLevelScalar(v, ref context);
            endpoint.SetMute(v <= 0.001f, ref context);
        }

        /// <summary>Same 2% steps as the Windows volume keys.</summary>
        public void Step(bool up)
        {
            if (endpoint == null) return;
            double unit = 0.02;
            double next = Math.Round(Level / unit) * unit + (up ? unit : -unit);
            if (Muted && up) endpoint.SetMute(false, ref context);
            SetLevel(next);
        }

        public void ToggleMute()
        {
            if (endpoint == null) return;
            endpoint.SetMute(!Muted, ref context);
        }

        int IAudioEndpointVolumeCallback.OnNotify(IntPtr data)
        {
            try
            {
                var ctx = Marshal.PtrToStructure<Guid>(data);
                if (ctx != context) Application.Current?.Dispatcher.BeginInvoke(new Action(() => ExternalChange?.Invoke()));
            }
            catch { }
            return 0;
        }

        int IMMNotificationClient.OnDefaultDeviceChanged(int flow, int role, string id)
        {
            if (flow == 0 && role == 1) Application.Current?.Dispatcher.BeginInvoke(new Action(Bind));
            return 0;
        }
        int IMMNotificationClient.OnDeviceStateChanged(string id, int state) => 0;
        int IMMNotificationClient.OnDeviceAdded(string id) => 0;
        int IMMNotificationClient.OnDeviceRemoved(string id) => 0;
        int IMMNotificationClient.OnPropertyValueChanged(string id, PropertyKey key) => 0;
    }

    /// <summary>Built-in display brightness through WMI (laptops). External monitors are left alone.</summary>
    public sealed class BrightnessService
    {
        public static BrightnessService Shared { get; } = new();
        public event Action<double> Changed;
        private ManagementEventWatcher watcher;
        private DateTime lastOwnChange = DateTime.MinValue;

        public bool Available { get; private set; }

        public void Start()
        {
            try
            {
                Available = Read() >= 0;
                if (!Available) return;
                watcher = new ManagementEventWatcher(new ManagementScope(@"root\WMI"), new EventQuery("SELECT * FROM WmiMonitorBrightnessEvent"));
                watcher.EventArrived += (_, e) =>
                {
                    double level = Convert.ToDouble(e.NewEvent.Properties["Brightness"].Value) / 100.0;
                    Application.Current?.Dispatcher.BeginInvoke(new Action(() => Changed?.Invoke(level)));
                };
                watcher.Start();
            }
            catch { Available = false; }
        }

        public double Read()
        {
            try
            {
                using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentBrightness FROM WmiMonitorBrightness");
                foreach (ManagementObject o in searcher.Get())
                    return Convert.ToDouble(o["CurrentBrightness"]) / 100.0;
            }
            catch { }
            return -1;
        }

        public void Set(double level)
        {
            try
            {
                lastOwnChange = DateTime.Now;
                using var cls = new ManagementClass(@"root\WMI", "WmiMonitorBrightnessMethods", null);
                foreach (ManagementObject o in cls.GetInstances())
                    o.InvokeMethod("WmiSetBrightness", new object[] { (uint)1, (byte)Math.Round(Math.Clamp(level, 0, 1) * 100) });
            }
            catch { }
        }
    }

    /// <summary>
    /// Takes over the volume keys (low-level keyboard hook), so the Windows volume flyout doesn't
    /// appear and the island is the only place the change shows.
    /// </summary>
    public sealed class KeyboardHook
    {
        public static KeyboardHook Shared { get; } = new();
        /// <summary>Return true to swallow the key. Called with VK_VOLUME_UP/DOWN/MUTE.</summary>
        public Func<int, bool> OnVolumeKey;
        private IntPtr hook;
        private Native.LowLevelProc proc;
        private readonly bool[] swallowed = new bool[256];

        public void Start()
        {
            proc = Callback;
            hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, proc, Native.GetModuleHandle(null), 0);
        }

        public void Stop()
        {
            if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }

        private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                int vk = Marshal.ReadInt32(lParam);
                if (vk == 0xAD || vk == 0xAE || vk == 0xAF)
                {
                    int msg = wParam.ToInt32();
                    if (msg == Native.WM_KEYDOWN || msg == Native.WM_SYSKEYDOWN)
                    {
                        if (OnVolumeKey != null && OnVolumeKey(vk)) { swallowed[vk] = true; return (IntPtr)1; }
                    }
                    else if ((msg == Native.WM_KEYUP || msg == Native.WM_SYSKEYUP) && swallowed[vk])
                    {
                        swallowed[vk] = false;
                        return (IntPtr)1;
                    }
                }
            }
            return Native.CallNextHookEx(hook, nCode, wParam, lParam);
        }
    }
}
