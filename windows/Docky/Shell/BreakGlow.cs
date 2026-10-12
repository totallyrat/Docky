using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Docky.Core;

namespace Docky.Shell
{
    /// <summary>
    /// The warm, soft glow around the screen during a Pomodoro break. Unlike the intro it never
    /// flashes: it fades in slowly, breathes gently and drifts through warm tones until the break
    /// ends or the island is put away.
    /// </summary>
    public sealed class BreakGlow
    {
        private List<OverlayPane> panes;
        private readonly List<Canvas> faders = new();
        private bool hiding;
        public Action Raise; // keeps the island above the glow

        public bool IsShowing => panes != null && !hiding;

        public void Show()
        {
            if (panes != null)
            {
                hiding = false;
                foreach (var f in faders) Anim.To(f, UIElement.OpacityProperty, 1, 1600, Anim.EaseInOut);
                return;
            }
            double W = SystemParameters.PrimaryScreenWidth, H = SystemParameters.PrimaryScreenHeight;
            var wash = new EdgeMask(W, H, 200, 110, 0.12, tint: Color.FromRgb(255, 158, 107), strength: 0.16);
            var outer = new EdgeMask(W, H, 150, 80, 0.16);
            var inner = new EdgeMask(W, H, 44, 24, 0.3);
            var conic = GlowKit.Conic(GlowKit.Warm);

            panes = new List<OverlayPane>();
            faders.Clear();
            hiding = false;
            var spins = new List<RotateTransform>();
            var breathers = new List<Grid>();
            foreach (var region in GlowKit.Partition(W, H, 300))
            {
                var pane = new OverlayPane(region);
                var fader = new Canvas { Width = region.Width, Height = region.Height, Opacity = 0 };
                var breather = new Grid { Width = region.Width, Height = region.Height };
                // The warm wash: a full-screen image offset so this pane shows its slice.
                var washImage = new Image { Source = wash.Bitmap, Width = W, Height = H, Stretch = Stretch.Fill };
                RenderOptions.SetBitmapScalingMode(washImage, BitmapScalingMode.Linear);
                // Cached layers: breathing only re-composites them, it never redraws the glow.
                var washHolder = new Canvas { Width = region.Width, Height = region.Height, ClipToBounds = true, CacheMode = new BitmapCache() };
                Canvas.SetLeft(washImage, -region.X);
                Canvas.SetTop(washImage, -region.Y);
                washHolder.Children.Add(washImage);
                breather.Children.Add(washHolder);
                foreach (var (mask, opacity) in new[] { (outer, 0.62), (inner, 0.45) })
                {
                    var (shape, spin) = pane.AddMaskedConic(breather, conic, mask.Bitmap, W, H, opacity);
                    shape.CacheMode = new BitmapCache();
                    spins.Add(spin);
                }
                fader.Children.Add(breather);
                pane.Root.Children.Add(fader);
                panes.Add(pane);
                faders.Add(fader);
                breathers.Add(breather);
                pane.Show();
            }

            // Start every pane's animations in the same tick so the seams never drift apart.
            var drift = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(24)) { RepeatBehavior = RepeatBehavior.Forever };
            Timeline.SetDesiredFrameRate(drift, 12); // slow changes: a dozen steps a second is imperceptible and cheap
            var breathe = new DoubleAnimation(0.72, 1, TimeSpan.FromSeconds(3.6)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = Anim.EaseInOut };
            Timeline.SetDesiredFrameRate(breathe, 12);
            var fadeIn = new DoubleAnimation(0, 1, TimeSpan.FromSeconds(1.6)) { EasingFunction = Anim.EaseInOut };
            Timeline.SetDesiredFrameRate(fadeIn, 40);
            foreach (var s in spins) s.BeginAnimation(RotateTransform.AngleProperty, drift);
            foreach (var b in breathers) b.BeginAnimation(UIElement.OpacityProperty, breathe);
            foreach (var f in faders) f.BeginAnimation(UIElement.OpacityProperty, fadeIn);
            Raise?.Invoke();
        }

        public void Hide()
        {
            if (panes == null || hiding) return;
            hiding = true;
            var closing = panes;
            var fadeOut = new DoubleAnimation(0, TimeSpan.FromSeconds(1.1)) { EasingFunction = Anim.EaseInOut };
            Timeline.SetDesiredFrameRate(fadeOut, 40);
            fadeOut.Completed += (_, _) =>
            {
                if (!hiding || panes != closing) return;
                foreach (var p in closing) p.Close();
                panes = null;
                faders.Clear();
                hiding = false;
            };
            foreach (var f in faders) f.BeginAnimation(UIElement.OpacityProperty, fadeOut);
        }
    }
}
