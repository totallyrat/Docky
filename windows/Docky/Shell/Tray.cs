using System;
using System.Drawing;
using System.Windows.Forms;

namespace Docky.Shell
{
    /// <summary>The notification-area icon: quick access to Settings, setup, Pomodoro and Quit.</summary>
    public sealed class Tray : IDisposable
    {
        private readonly NotifyIcon icon;

        public Tray(Action openSettings, Action runSetup, Action playIntro, Action startPomodoro, Action checkForUpdates, Action quit)
        {
            var menu = new ContextMenuStrip { Renderer = new ToolStripProfessionalRenderer(new DarkColors()), ShowImageMargin = false };
            menu.ForeColor = Color.White;
            menu.Font = new Font("Segoe UI", 9.5f);
            void Add(string text, Action a) => menu.Items.Add(new ToolStripMenuItem(text, null, (_, _) => a()) { ForeColor = Color.White, Padding = new Padding(4, 3, 4, 3) });
            Add("Docky Settings…", openSettings);
            Add("Start Pomodoro", startPomodoro);
            Add("Run Setup Again", runSetup);
            Add("Check for Updates", checkForUpdates);
            Add("Play Intro", playIntro);
            menu.Items.Add(new ToolStripSeparator());
            Add("Quit Docky", quit);

            icon = new NotifyIcon
            {
                Text = "Docky",
                Icon = LoadIcon(),
                ContextMenuStrip = menu,
                Visible = true,
            };
            icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) openSettings(); };
        }

        private static Icon LoadIcon()
        {
            try
            {
                using var s = typeof(Tray).Assembly.GetManifestResourceStream("Docky.ico");
                if (s != null) return new Icon(s, SystemInformation.SmallIconSize);
            }
            catch { }
            return SystemIcons.Application;
        }

        public void Dispose()
        {
            icon.Visible = false;
            icon.Dispose();
        }

        private sealed class DarkColors : ProfessionalColorTable
        {
            private static readonly Color Back = Color.FromArgb(38, 38, 40), Hover = Color.FromArgb(60, 60, 64), Line = Color.FromArgb(60, 60, 64);
            public override Color ToolStripDropDownBackground => Back;
            public override Color ImageMarginGradientBegin => Back;
            public override Color ImageMarginGradientMiddle => Back;
            public override Color ImageMarginGradientEnd => Back;
            public override Color MenuBorder => Line;
            public override Color MenuItemBorder => Hover;
            public override Color MenuItemSelected => Hover;
            public override Color MenuItemSelectedGradientBegin => Hover;
            public override Color MenuItemSelectedGradientEnd => Hover;
            public override Color SeparatorDark => Line;
            public override Color SeparatorLight => Back;
        }
    }
}
