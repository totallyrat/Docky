using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Docky.Core
{
    public static class Theme
    {
        public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");
        public static readonly FontFamily Display = new("Segoe UI Variable Display, Segoe UI");
        public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

        public static readonly Color Orange = Color.FromRgb(255, 159, 10);
        public static readonly Color Focus = Color.FromRgb(255, 107, 84);
        public static readonly Color Rest = Color.FromRgb(92, 219, 158);
        public static readonly Color Yellow = Color.FromRgb(255, 199, 51);
        public static readonly Color Green = Color.FromRgb(52, 217, 102);
        public static readonly Color Blue = Color.FromRgb(82, 153, 255);
        public static readonly Color Pink = Color.FromRgb(255, 115, 166);
        public static readonly Color Red = Color.FromRgb(255, 69, 69);
        public static readonly Color Purple = Color.FromRgb(158, 128, 255);
        public static readonly Color Warm = Color.FromRgb(255, 179, 115);

        public static SolidColorBrush Brush(Color c, double alpha = 1)
        {
            var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(255 * alpha), c.R, c.G, c.B));
            b.Freeze();
            return b;
        }

        public static SolidColorBrush White(double alpha) => Brush(Colors.White, alpha);

        public static TextBlock Text(string s, double size, FontWeight weight, Brush brush, bool display = false)
            => new()
            {
                Text = s,
                FontSize = size,
                FontWeight = weight,
                Foreground = brush,
                FontFamily = display ? Display : Font,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };

        public static TextBlock Glyph(string glyph, double size, Brush brush)
            => new()
            {
                Text = glyph,
                FontFamily = Icons,
                FontSize = size,
                Foreground = brush,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
            };

        public static string Clock(double seconds, bool roundUp = false)
        {
            int total = Math.Max(0, (int)(roundUp ? Math.Ceiling(seconds) : Math.Floor(seconds)));
            int h = total / 3600, m = total % 3600 / 60, s = total % 60;
            return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
        }

        public static string Time(DateTime t)
            => SettingsStore.Current.Use24Hour ? t.ToString("H:mm") : t.ToString("h:mm tt");
    }

    /// <summary>Segoe MDL2 / Fluent icon code points.</summary>
    public static class G
    {
        public const string Play = "", Pause = "", Prev = "", Next = "";
        public const string Volume = "", Volume1 = "", Volume2 = "", Volume3 = "", Mute = "";
        public const string Brightness = "", Timer = "", Alarm = "", Bell = "", Calendar = "";
        public const string Clipboard = "", Settings = "", Music = "", Add = "", Close = "";
        public const string Check = "", Up = "", Down = "", Bluetooth = "", Headphones = "";
        public const string Drive = "", Bolt = "", Moon = "", Lock = "", Unlock = "";
        public const string Share = "", Delete = "", Repeat = "", Shield = "", Eye = "";
        public const string Focus = "", Coffee = "", Star = "", Video = "", Open = "";
        public const string Download = "\uE896", Wave = "\uE76E"; // Wave is a friendly smiley
        public const string Hand = "", Power = "", Skip = "", Sparkle = "", List = "";

        /// <summary>The speaker glyph for a volume level.</summary>
        public static string VolumeFor(double level, bool muted = false)
            => muted || level <= 0.001 ? Mute : level < 0.34 ? Volume1 : level < 0.67 ? Volume2 : Volume3;
    }

    /// <summary>Small animation helpers.</summary>
    public static class Anim
    {
        public static IEasingFunction EaseOut => new CubicEase { EasingMode = EasingMode.EaseOut };
        public static IEasingFunction EaseInOut => new SineEase { EasingMode = EasingMode.EaseInOut };

        public static void To(DependencyObject target, DependencyProperty prop, double to, double ms,
                              IEasingFunction ease = null, double delayMs = 0, Action done = null)
        {
            var a = new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms))
            {
                EasingFunction = ease ?? EaseOut,
                BeginTime = TimeSpan.FromMilliseconds(delayMs),
            };
            if (done != null) a.Completed += (_, _) => done();
            if (target is UIElement ui) ui.BeginAnimation(prop, a);
            else if (target is Animatable an) an.BeginAnimation(prop, a);
        }
    }

    /// <summary>A shared 4 Hz tick for countdowns and progress, so views don't each run timers.</summary>
    public static class UiTicker
    {
        public static event Action Tick;
        private static readonly DispatcherTimer timer;

        static UiTicker()
        {
            timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            timer.Tick += (_, _) => Tick?.Invoke();
            timer.Start();
        }

        /// <summary>Subscribe while the element is on screen.</summary>
        public static void Attach(FrameworkElement element, Action onTick)
        {
            void Handler() => onTick();
            element.Loaded += (_, _) => { Tick -= Handler; Tick += Handler; onTick(); };
            element.Unloaded += (_, _) => Tick -= Handler;
        }
    }
}
