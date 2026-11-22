# AI Limits — a tiny Windows widget: Claude subscription limits and API balances of other AIs.
# Launch: double-click "Start AI Limits.vbs" (or "Start (debug).bat" for a console with errors).
# Settings and keys: %APPDATA%\AILimits\config.json (keys are encrypted with Windows DPAPI for your account).

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$AppName   = 'AI Limits'
$ScriptDir = $PSScriptRoot
$AppDir    = Join-Path $env:APPDATA 'AILimits'
$CfgPath   = Join-Path $AppDir 'config.json'
$LogPath   = Join-Path $AppDir 'error.log'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Limits.lnk'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $msg) -Encoding UTF8 } catch {}
}

# ---------- single instance ----------
$createdNew = $false
$script:mutex = [System.Threading.Mutex]::new($true, 'Local\AILimitsWidget', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('AI Limits is already running — look for its icon in the tray next to the clock.', $AppName) | Out-Null
    exit
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace AILimitsUI {
    // Borderless window with per-pixel alpha: smooth anti-aliased corners over any wallpaper.
    public class LayeredForm : Form {
        protected override CreateParams CreateParams {
            get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80000 | 0x80; return cp; } // WS_EX_LAYERED | WS_EX_TOOLWINDOW
        }
        public event EventHandler HotKey;
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312 && HotKey != null) HotKey(this, EventArgs.Empty);   // WM_HOTKEY
            base.WndProc(ref m);
        }
    }

    public static class Layered {
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

        // content: opaque image (ClearType text on the card colour); mask: anti-aliased card shapes in its alpha channel.
        public static Bitmap Compose(Bitmap content, Bitmap mask) {
            int w = content.Width, h = content.Height;
            Rectangle r = new Rectangle(0, 0, w, h);
            Bitmap result = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            BitmapData c = content.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            BitmapData m = mask.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            BitmapData o = result.LockBits(r, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            int n = c.Stride * h;
            byte[] cb = new byte[n], mb = new byte[n];
            Marshal.Copy(c.Scan0, cb, 0, n);
            Marshal.Copy(m.Scan0, mb, 0, n);
            for (int i = 0; i < n; i += 4) cb[i + 3] = mb[i + 3];
            Marshal.Copy(cb, 0, o.Scan0, n);
            content.UnlockBits(c); mask.UnlockBits(m); result.UnlockBits(o);
            return result;
        }

        public static void Apply(IntPtr hwnd, Bitmap argb, int x, int y) {
            IntPtr screen = GetDC(IntPtr.Zero);
            IntPtr mem = CreateCompatibleDC(screen);
            IntPtr hb = argb.GetHbitmap(Color.FromArgb(0));
            IntPtr old = SelectObject(mem, hb);
            POINT dst = new POINT(); dst.x = x; dst.y = y;
            POINT src = new POINT();
            SIZE sz = new SIZE(); sz.cx = argb.Width; sz.cy = argb.Height;
            BLENDFUNCTION bf = new BLENDFUNCTION(); bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
            UpdateLayeredWindow(hwnd, screen, ref dst, ref sz, mem, ref src, 0, ref bf, 2);
            SelectObject(mem, old); DeleteObject(hb); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
        }
    }

    // Frosted glass: a blurred copy of what is behind the widget.
    // Screen capture without CAPTUREBLT skips layered windows, so the widget never captures itself.
    public static class Glass {
        static void BoxBlur(Bitmap b, int r) {
            int w = b.Width, h = b.Height;
            Rectangle rect = new Rectangle(0, 0, w, h);
            BitmapData d = b.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            int stride = d.Stride, n = stride * h;
            byte[] src = new byte[n], tmp = new byte[n];
            Marshal.Copy(d.Scan0, src, 0, n);
            for (int pass = 0; pass < 2; pass++) {
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) for (int c = 0; c < 3; c++) {
                    int sum = 0, cnt = 0;
                    for (int k = -r; k <= r; k++) { int xx = Math.Min(w - 1, Math.Max(0, x + k)); sum += src[y * stride + xx * 4 + c]; cnt++; }
                    tmp[y * stride + x * 4 + c] = (byte)(sum / cnt);
                }
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) for (int c = 0; c < 3; c++) {
                    int sum = 0, cnt = 0;
                    for (int k = -r; k <= r; k++) { int yy = Math.Min(h - 1, Math.Max(0, y + k)); sum += tmp[yy * stride + x * 4 + c]; cnt++; }
                    src[y * stride + x * 4 + c] = (byte)(sum / cnt);
                }
            }
            for (int i = 3; i < n; i += 4) src[i] = 255;
            Marshal.Copy(src, 0, d.Scan0, n);
            b.UnlockBits(d);
        }

        [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
        [DllImport("dwmapi.dll")] static extern int DwmFlush();

        public static Bitmap Backdrop(IntPtr hwnd, int x, int y, int w, int h) {
            // hide the widget from the capture for one frame, so its own text never shows up in the blur
            bool hidden = false;
            try { hidden = hwnd != IntPtr.Zero && SetWindowDisplayAffinity(hwnd, 0x11); if (hidden) DwmFlush(); } catch { }
            try {
                return Capture(x, y, w, h);
            } finally {
                if (hidden) { try { SetWindowDisplayAffinity(hwnd, 0); } catch { } }
            }
        }

        static Bitmap Capture(int x, int y, int w, int h) {
            try {
                using (Bitmap shot = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
                    using (Graphics g = Graphics.FromImage(shot)) g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
                    int sw = Math.Max(2, w / 8), sh = Math.Max(2, h / 8);
                    using (Bitmap small = new Bitmap(sw, sh, PixelFormat.Format32bppArgb)) {
                        using (Graphics g = Graphics.FromImage(small)) {
                            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                            g.DrawImage(shot, new Rectangle(0, 0, sw, sh));
                        }
                        BoxBlur(small, 2);
                        Bitmap result = new Bitmap(w, h, PixelFormat.Format32bppArgb);
                        using (Graphics g = Graphics.FromImage(result))
                        using (ImageAttributes ia = new ImageAttributes()) {
                            ia.SetWrapMode(WrapMode.TileFlipXY);
                            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                            g.DrawImage(small, new Rectangle(0, 0, w, h), 0, 0, sw, sh, GraphicsUnit.Pixel, ia);
                        }
                        return result;
                    }
                }
            } catch { return null; }
        }
    }

    // Vector icons drawn around an exact centre point (no font side-bearings, no baseline offsets).
    public static class Icons {
        static Pen MakePen(Color c, float w) {
            Pen p = new Pen(c, w);
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            return p;
        }
        static void Prep(Graphics g) { g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality; }

        public static void Minus(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g);
            float w = s * 0.75f, h = Math.Max(1.8f, s * 0.13f);
            using (GraphicsPath p = new GraphicsPath())
            using (SolidBrush b = new SolidBrush(c)) {
                float x = cx - w / 2f, y = cy - h / 2f, d = h;
                p.AddArc(x, y, d, d, 90, 180);
                p.AddArc(x + w - d, y, d, d, 270, 180);
                p.CloseFigure();
                g.FillPath(b, p);
            }
        }

        public static void Refresh(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g);
            float r = s * 0.40f, pw = Math.Max(1.6f, s * 0.12f);
            float start = -60f, sweep = 290f;
            using (Pen pen = MakePen(c, pw)) g.DrawArc(pen, cx - r, cy - r, 2 * r, 2 * r, start, sweep);
            double a = start * Math.PI / 180.0;
            float px = cx + (float)(r * Math.Cos(a)), py = cy + (float)(r * Math.Sin(a));
            float dx = (float)Math.Sin(a), dy = (float)-Math.Cos(a);   // tangent against the sweep
            float nx = (float)Math.Cos(a), ny = (float)Math.Sin(a);    // radial
            float ah = s * 0.26f;
            PointF[] tri = {
                new PointF(px + dx * ah, py + dy * ah),
                new PointF(px - dx * ah * 0.15f + nx * ah * 0.8f, py - dy * ah * 0.15f + ny * ah * 0.8f),
                new PointF(px - dx * ah * 0.15f - nx * ah * 0.8f, py - dy * ah * 0.15f - ny * ah * 0.8f)
            };
            using (SolidBrush b = new SolidBrush(c)) g.FillPolygon(b, tri);
        }

        public static void Chart(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g);
            float bw = Math.Max(1.8f, s * 0.16f), gap = s * 0.14f;
            float[] hs = { 0.45f, 0.75f, 0.60f };
            float x = cx - (3 * bw + 2 * gap) / 2f, baseY = cy + s * 0.40f;
            using (SolidBrush b = new SolidBrush(c)) {
                for (int i = 0; i < 3; i++) {
                    float h = s * hs[i];
                    using (GraphicsPath p = new GraphicsPath()) {
                        float px = x + i * (bw + gap), py = baseY - h, d = bw;
                        p.AddArc(px, py, d, d, 180, 180);
                        p.AddLine(px + bw, py + d / 2f, px + bw, baseY);
                        p.AddLine(px + bw, baseY, px, baseY);
                        p.CloseFigure();
                        g.FillPath(b, p);
                    }
                }
            }
        }

        public static void Gear(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g);
            int teeth = 8;
            float ro = s * 0.47f, ri = s * 0.35f, hole = s * 0.14f, pw = Math.Max(1.4f, s * 0.10f);
            PointF[] pts = new PointF[teeth * 4];
            for (int k = 0; k < teeth; k++) {
                double baseA = k * 2 * Math.PI / teeth;
                double[] ang = { baseA - 0.30, baseA - 0.16, baseA + 0.16, baseA + 0.30 };
                float[] rad = { ri, ro, ro, ri };
                for (int j = 0; j < 4; j++) pts[k * 4 + j] = new PointF(cx + (float)(rad[j] * Math.Cos(ang[j])), cy + (float)(rad[j] * Math.Sin(ang[j])));
            }
            using (Pen pen = MakePen(c, pw)) {
                g.DrawPolygon(pen, pts);
                g.DrawEllipse(pen, cx - hole, cy - hole, 2 * hole, 2 * hole);
            }
        }

        // Thin line icons drawn on a 16-unit grid centred at (cx, cy); s = icon size in pixels.
        static PointF P(float cx, float cy, float k, float x, float y) { return new PointF(cx + (x - 8f) * k, cy + (y - 8f) * k); }
        static void L(Graphics g, Pen pen, float cx, float cy, float k, float x1, float y1, float x2, float y2) { g.DrawLine(pen, P(cx, cy, k, x1, y1), P(cx, cy, k, x2, y2)); }
        static Pen LinePen(Color c, float k) { return MakePen(c, Math.Max(1.3f, 1.5f * k)); }

        public static void LineBars(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g); float k = s / 16f;
            using (Pen pen = LinePen(c, k)) { L(g, pen, cx, cy, k, 3, 13, 3, 8); L(g, pen, cx, cy, k, 8, 13, 8, 3); L(g, pen, cx, cy, k, 13, 13, 13, 6); }
        }
        public static void LineSliders(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g); float k = s / 16f;
            using (Pen pen = LinePen(c, k)) {
                L(g, pen, cx, cy, k, 2.5f, 5, 9.5f, 5); L(g, pen, cx, cy, k, 12.5f, 5, 13.5f, 5);
                L(g, pen, cx, cy, k, 2.5f, 11, 3.5f, 11); L(g, pen, cx, cy, k, 6.5f, 11, 13.5f, 11);
                PointF a = P(cx, cy, k, 11, 5), b = P(cx, cy, k, 5, 11); float r = 1.5f * k;
                g.DrawEllipse(pen, a.X - r, a.Y - r, 2 * r, 2 * r);
                g.DrawEllipse(pen, b.X - r, b.Y - r, 2 * r, 2 * r);
            }
        }
        public static void LineRefresh(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g); float k = s / 16f;
            using (Pen pen = LinePen(c, k)) {
                float r = 5f * k;
                g.DrawArc(pen, cx - r, cy - r, 2 * r, 2 * r, 0f, 314f);
                g.DrawLines(pen, new PointF[] { P(cx, cy, k, 13, 2.5f), P(cx, cy, k, 13, 5.3f), P(cx, cy, k, 10.2f, 5.3f) });
            }
        }
        public static void LineDash(Graphics g, float cx, float cy, float s, Color c) {
            Prep(g); float k = s / 16f;
            using (Pen pen = LinePen(c, k)) L(g, pen, cx, cy, k, 4, 8, 12, 8);
        }

        // Text centred by its real ink bounds (used for the tray badge).
        public static void TextCentered(Graphics g, string text, string family, FontStyle style, float px, Color c, RectangleF box) {
            Prep(g);
            using (FontFamily ff = new FontFamily(family))
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddString(text, ff, (int)style, px, new PointF(0, 0), StringFormat.GenericTypographic);
                RectangleF b = p.GetBounds();
                using (Matrix m = new Matrix()) {
                    m.Translate(box.X + (box.Width - b.Width) / 2f - b.X, box.Y + (box.Height - b.Height) / 2f - b.Y);
                    p.Transform(m);
                }
                using (SolidBrush br = new SolidBrush(c)) g.FillPath(br, p);
            }
        }
    }

    // Pill-shaped button with anti-aliased edges.
    // Flat colours for context menus (tray menu, "+ Add service")
    public class FlatColors : ProfessionalColorTable {
        public static Color Bg = Color.FromArgb(0xFA, 0xFA, 0xF8);
        public static Color Hover = Color.FromArgb(0xEC, 0xEB, 0xE7);
        public static Color Line = Color.FromArgb(0xD6, 0xD5, 0xD0);
        public override Color ToolStripDropDownBackground { get { return Bg; } }
        public override Color ImageMarginGradientBegin { get { return Bg; } }
        public override Color ImageMarginGradientMiddle { get { return Bg; } }
        public override Color ImageMarginGradientEnd { get { return Bg; } }
        public override Color MenuBorder { get { return Line; } }
        public override Color MenuItemBorder { get { return Hover; } }
        public override Color MenuItemSelected { get { return Hover; } }
        public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
        public override Color MenuItemSelectedGradientEnd { get { return Hover; } }
        public override Color MenuItemPressedGradientBegin { get { return Hover; } }
        public override Color MenuItemPressedGradientEnd { get { return Hover; } }
        public override Color CheckBackground { get { return Hover; } }
        public override Color CheckSelectedBackground { get { return Line; } }
        public override Color CheckPressedBackground { get { return Line; } }
        public override Color ButtonSelectedBorder { get { return Hover; } }
        public override Color SeparatorDark { get { return Line; } }
        public override Color SeparatorLight { get { return Bg; } }
    }

    public class RoundButton : Button {
        public Color HoverColor = Color.Empty;
        public Color BorderColor = Color.Empty;
        public float Radius = -1f;   // < 0 = pill
        bool hover;
        public RoundButton() {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Parent != null ? Parent.BackColor : SystemColors.Control);
            Color bg = (hover && !HoverColor.IsEmpty && Enabled) ? HoverColor : BackColor;
            if (!Enabled) bg = Color.FromArgb(120, bg);
            float h = Height - 1f, w = Width - 1f, d = Math.Min(h, w);
            if (Radius >= 0) d = Math.Min(d, Radius * 2f);
            using (GraphicsPath p = new GraphicsPath()) {
                if (d <= 0) { p.AddRectangle(new RectangleF(0.5f, 0.5f, w, h)); }
                else {
                    p.AddArc(0.5f, 0.5f, d, d, 180, 90);
                    p.AddArc(w - d + 0.5f, 0.5f, d, d, 270, 90);
                    p.AddArc(w - d + 0.5f, h - d + 0.5f, d, d, 0, 90);
                    p.AddArc(0.5f, h - d + 0.5f, d, d, 90, 90);
                }
                p.CloseFigure();
                using (SolidBrush b = new SolidBrush(bg)) g.FillPath(b, p);
                if (!BorderColor.IsEmpty) using (Pen pen = new Pen(BorderColor, 1f)) g.DrawPath(pen, p);
            }
            Color fg = Enabled ? ForeColor : Color.FromArgb(140, ForeColor);
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, fg,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
        }
    }

    // ---------- desktop helpers: hotkey, fullscreen detection ----------
    public static class Win {
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
        [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }

        // "Ctrl+Alt+L" -> registered as hotkey id 1 on the window; returns false if the combo is taken or invalid
        public static bool SetHotKey(IntPtr hwnd, string combo) {
            UnregisterHotKey(hwnd, 1);
            if (string.IsNullOrWhiteSpace(combo)) return true;
            uint mods = 0x4000; uint vk = 0;   // MOD_NOREPEAT
            foreach (string raw in combo.Split('+')) {
                string p = raw.Trim().ToLowerInvariant();
                if (p == "ctrl" || p == "control") mods |= 2;
                else if (p == "alt") mods |= 1;
                else if (p == "shift") mods |= 4;
                else if (p == "win") mods |= 8;
                else {
                    Keys k;
                    if (p.Length == 1 && char.IsDigit(p[0])) p = "D" + p;
                    if (!Enum.TryParse(p, true, out k)) return false;
                    vk = (uint)k;
                }
            }
            if (vk == 0 || (mods & 0xF) == 0) return false;
            return RegisterHotKey(hwnd, 1, mods, vk);
        }

        // true when a game, video or presentation fills the monitor the widget is on
        public static bool FullscreenOnMyMonitor(IntPtr self) {
            int st;
            if (SHQueryUserNotificationState(out st) == 0 && (st == 3 || st == 4)) return true;   // D3D full screen, presentation
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero || fg == self || fg == GetShellWindow() || fg == GetDesktopWindow()) return false;
            System.Text.StringBuilder sb = new System.Text.StringBuilder(64);
            GetClassName(fg, sb, 64);
            string cls = sb.ToString();
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") return false;
            IntPtr mon = MonitorFromWindow(fg, 2);
            if (mon != MonitorFromWindow(self, 2)) return false;
            MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(mon, ref mi)) return false;
            RECT r; if (!GetWindowRect(fg, out r)) return false;
            return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
        }
    }

    // ---------- API value of subscription use, from local Claude Code / Codex logs ----------
    public class Price { public string Pattern; public double In, Out, Read, W5, W1; }

    public class UsageSummary {
        public double MonthCost, TodayCost, MonthTokens, MonthRequests;
        public double[] Hours = new double[24];
        public List<KeyValuePair<string, double>> Days = new List<KeyValuePair<string, double>>();
        public List<KeyValuePair<string, double>> Models = new List<KeyValuePair<string, double>>();
        public List<KeyValuePair<string, double>> Projects = new List<KeyValuePair<string, double>>();
    }

    public static class UsageLog {
        static readonly RegexOptions RO = RegexOptions.Compiled | RegexOptions.CultureInvariant;
        static readonly Regex rxReq = new Regex("\"requestId\":\"([^\"]+)\"", RO);
        static readonly Regex rxMsgId = new Regex("\"id\":\"(msg_[^\"]+)\"", RO);
        static readonly Regex rxModel = new Regex("\"model\":\"([^\"]+)\"", RO);
        static readonly Regex rxTs = new Regex("\"timestamp\":\"([^\"]+)\"", RO);
        static readonly Regex rxCwd = new Regex("\"cwd\":\"((?:[^\"\\\\]|\\\\.)*)\"", RO);
        static readonly Regex rxIn = new Regex("\"input_tokens\":(\\d+)", RO);
        static readonly Regex rxOut = new Regex("\"output_tokens\":(\\d+)", RO);
        static readonly Regex rxCc = new Regex("\"cache_creation_input_tokens\":(\\d+)", RO);
        static readonly Regex rxCr = new Regex("\"cache_read_input_tokens\":(\\d+)", RO);
        static readonly Regex rx5m = new Regex("\"ephemeral_5m_input_tokens\":(\\d+)", RO);
        static readonly Regex rx1h = new Regex("\"ephemeral_1h_input_tokens\":(\\d+)", RO);
        static readonly Regex rxStop = new Regex("\"stop_reason\":(null|\"[^\"]*\")", RO);
        static readonly Regex rxLast = new Regex("\"last_token_usage\":\\{([^}]*)\\}", RO);
        static readonly Regex rxTotal = new Regex("\"total_token_usage\":\\{([^}]*)\\}", RO);
        static readonly Regex rxTotTok = new Regex("\"total_tokens\":(\\d+)", RO);
        static readonly Regex rxCached = new Regex("\"cached_input_tokens\":(\\d+)", RO);

        class Rec { public string Key, Model, Project, Hour, Tool; public long In, Out, W5, W1, Cr; public long FirstOffset; public bool Done; }

        static long N(Regex rx, string s) { Match m = rx.Match(s); return m.Success ? long.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 0; }
        static string S(Regex rx, string s) { Match m = rx.Match(s); return m.Success ? m.Groups[1].Value : null; }

        static string HourKey(string ts) {
            DateTime t;
            if (ts != null && DateTime.TryParse(ts, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out t))
                return t.ToLocalTime().ToString("yyyy-MM-dd HH", CultureInfo.InvariantCulture);
            return DateTime.Now.ToString("yyyy-MM-dd HH", CultureInfo.InvariantCulture);
        }

        static string ProjectName(string cwd) {
            if (string.IsNullOrEmpty(cwd)) return "(unknown)";
            string p = cwd.Replace("\\\\", "\\").TrimEnd('\\', '/');
            int i = Math.Max(p.LastIndexOf('\\'), p.LastIndexOf('/'));
            string n = i >= 0 ? p.Substring(i + 1) : p;
            return n.Length == 0 ? p : n;
        }

        static string Clean(string s) { return (s ?? "").Replace("\t", " ").Replace("\n", " ").Replace("\r", " "); }

        // Reads only complete new lines of a file; returns the lines and their start offsets.
        static List<KeyValuePair<long, string>> ReadNewLines(string path, long start, out long endOfComplete) {
            var list = new List<KeyValuePair<long, string>>();
            endOfComplete = start;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (start > fs.Length) start = 0;
                long len = fs.Length - start;
                if (len <= 0) { endOfComplete = start; return list; }
                byte[] buf = new byte[len];
                fs.Seek(start, SeekOrigin.Begin);
                int read = 0;
                while (read < len) { int n = fs.Read(buf, read, (int)(len - read)); if (n <= 0) break; read += n; }
                int lineStart = 0;
                for (int i = 0; i < read; i++) {
                    if (buf[i] != (byte)'\n') continue;
                    string line = Encoding.UTF8.GetString(buf, lineStart, i - lineStart);
                    list.Add(new KeyValuePair<long, string>(start + lineStart, line));
                    lineStart = i + 1;
                }
                endOfComplete = start + lineStart;
            }
            return list;
        }

        // Incremental scan. State lives in stateDir: usage-<acct>.tsv, seen-<acct>.txt, offsets-<acct>.tsv.
        public static int Scan(string acct, string stateDir, string claudeProjects, string codexHome) {
            Directory.CreateDirectory(stateDir);
            string usageF = Path.Combine(stateDir, "usage-" + acct + ".tsv");
            string seenF = Path.Combine(stateDir, "seen-" + acct + ".txt");
            string offF = Path.Combine(stateDir, "offsets-" + acct + ".tsv");
            var seen = new HashSet<string>(File.Exists(seenF) ? File.ReadAllLines(seenF) : new string[0]);
            var offsets = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(offF)) foreach (string l in File.ReadAllLines(offF)) { string[] a = l.Split('\t'); if (a.Length >= 2) offsets[a[0]] = a; }
            var outLines = new List<string>();
            var newSeen = new List<string>();

            if (!string.IsNullOrEmpty(claudeProjects) && Directory.Exists(claudeProjects)) {
                foreach (string f in Directory.EnumerateFiles(claudeProjects, "*.jsonl", SearchOption.AllDirectories)) {
                    try {
                        long start = 0; string[] st;
                        if (offsets.TryGetValue(f, out st)) long.TryParse(st[1], out start);
                        FileInfo fi = new FileInfo(f);
                        long fileLen = fi.Length;
                        DateTime quietSince = fi.LastWriteTimeUtc;
                        if (fileLen == start) continue;
                        long endComplete;
                        var lines = ReadNewLines(f, start, out endComplete);
                        var recs = new Dictionary<string, Rec>();
                        var order = new List<Rec>();
                        Rec last = null;
                        foreach (var kv in lines) {
                            string s = kv.Value;
                            if (s.IndexOf("\"usage\"", StringComparison.Ordinal) < 0 || s.IndexOf("\"assistant\"", StringComparison.Ordinal) < 0) continue;
                            string model = S(rxModel, s);
                            if (model == null || model.StartsWith("<")) continue;
                            string mid = S(rxMsgId, s), req = S(rxReq, s);
                            string key = (req ?? "") + ":" + (mid ?? kv.Key.ToString(CultureInfo.InvariantCulture));
                            Rec r;
                            if (!recs.TryGetValue(key, out r)) {
                                r = new Rec { Key = key, Model = model, Tool = "claude", Project = ProjectName(S(rxCwd, s)), Hour = HourKey(S(rxTs, s)), FirstOffset = kv.Key };
                                recs[key] = r; order.Add(r);
                            }
                            long cc = N(rxCc, s), w1 = N(rx1h, s), w5 = rx5m.IsMatch(s) ? N(rx5m, s) : Math.Max(0, cc - w1);
                            r.In = Math.Max(r.In, N(rxIn, s)); r.Out = Math.Max(r.Out, N(rxOut, s));
                            r.Cr = Math.Max(r.Cr, N(rxCr, s)); r.W5 = Math.Max(r.W5, w5); r.W1 = Math.Max(r.W1, w1);
                            string stop = S(rxStop, s);
                            r.Done = stop != null && stop != "null";
                            last = r;
                        }
                        long newOffset = endComplete;
                        foreach (Rec r in order) {
                            if (r == last && !r.Done && quietSince > DateTime.UtcNow.AddMinutes(-10)) { newOffset = r.FirstOffset; continue; }   // reply still streaming
                            if (seen.Contains(r.Key)) continue;
                            seen.Add(r.Key); newSeen.Add(r.Key);
                            outLines.Add(string.Join("\t", r.Hour, r.Tool, Clean(r.Model), Clean(r.Project), r.In, r.Out, r.W5, r.W1, r.Cr));
                        }
                        offsets[f] = new[] { f, newOffset.ToString(CultureInfo.InvariantCulture) };
                    } catch { }
                }
            }

            if (!string.IsNullOrEmpty(codexHome)) {
                foreach (string sub in new[] { "sessions", "archived_sessions" }) {
                    string dir = Path.Combine(codexHome, sub);
                    if (!Directory.Exists(dir)) continue;
                    foreach (string f in Directory.EnumerateFiles(dir, "rollout-*.jsonl", SearchOption.AllDirectories)) {
                        try {
                            string[] st; long start = 0; string model = "gpt-5.5", cwd = "", prevTotal = "";
                            if (offsets.TryGetValue(f, out st)) {
                                long.TryParse(st[1], out start);
                                if (st.Length > 2) model = st[2];
                                if (st.Length > 3) cwd = st[3];
                                if (st.Length > 4) prevTotal = st[4];
                            }
                            long fileLen = new FileInfo(f).Length;
                            if (fileLen == start) continue;
                            long endComplete;
                            var lines = ReadNewLines(f, start, out endComplete);
                            string fname = Path.GetFileName(f);
                            foreach (var kv in lines) {
                                string s = kv.Value;
                                if (s.IndexOf("\"session_meta\"", StringComparison.Ordinal) >= 0) { string c = S(rxCwd, s); if (c != null) cwd = c; continue; }
                                if (s.IndexOf("\"turn_context\"", StringComparison.Ordinal) >= 0) { string m = S(rxModel, s); if (m != null) model = m; continue; }
                                if (s.IndexOf("\"token_count\"", StringComparison.Ordinal) < 0) continue;
                                string tot = S(rxTotal, s), lastU = S(rxLast, s);
                                if (tot == null || lastU == null) continue;
                                string total = N(rxTotTok, tot).ToString(CultureInfo.InvariantCulture);
                                if (total == prevTotal || total == "0") continue;
                                prevTotal = total;
                                string key = fname + ":" + total;
                                if (seen.Contains(key)) continue;
                                seen.Add(key); newSeen.Add(key);
                                long inp = N(rxIn, lastU), cached = N(rxCached, lastU), outp = N(rxOut, lastU);
                                outLines.Add(string.Join("\t", HourKey(S(rxTs, s)), "codex", Clean(model), Clean(ProjectName(cwd)), Math.Max(0, inp - cached), outp, 0, 0, cached));
                            }
                            offsets[f] = new[] { f, endComplete.ToString(CultureInfo.InvariantCulture), Clean(model), Clean(cwd), prevTotal };
                        } catch { }
                    }
                }
            }

            if (outLines.Count > 0) File.AppendAllLines(usageF, outLines);
            if (newSeen.Count > 0) File.AppendAllLines(seenF, newSeen);
            var offOut = new List<string>();
            foreach (var kv in offsets) offOut.Add(string.Join("\t", kv.Value));
            File.WriteAllLines(offF, offOut);
            return outLines.Count;
        }

        public static List<Price> LoadPrices(string tsvPath) {
            var list = new List<Price>();
            if (!File.Exists(tsvPath)) return list;
            foreach (string l in File.ReadAllLines(tsvPath)) {
                if (l.Length == 0 || l[0] == '#') continue;
                string[] a = l.Split('\t');
                if (a.Length < 6) continue;
                try {
                    Func<string, double> d = x => double.Parse(x.Trim(), CultureInfo.InvariantCulture);
                    list.Add(new Price { Pattern = a[0].Trim(), In = d(a[1]), Out = d(a[2]), Read = d(a[3]), W5 = d(a[4]), W1 = d(a[5]) });
                } catch { }
            }
            return list;
        }

        static Price FindPrice(List<Price> ps, string model, string tool) {
            foreach (Price p in ps) { try { if (Regex.IsMatch(model, p.Pattern, RegexOptions.IgnoreCase)) return p; } catch { } }
            string fallback = tool == "codex" ? "openai-default" : "claude-default";
            foreach (Price p in ps) if (p.Pattern == fallback) return p;
            return new Price { In = 3, Out = 15, Read = 0.3, W5 = 3.75, W1 = 6 };
        }

        public static string PrettyModel(string m) {
            string s = Regex.Replace(m ?? "", "-\\d{8}$", "");
            s = Regex.Replace(s, "^claude-", "", RegexOptions.IgnoreCase);
            return s;
        }

        public static UsageSummary Summarize(string acct, string stateDir, string pricesPath, DateTime now) {
            var sum = new UsageSummary();
            string usageF = Path.Combine(stateDir, "usage-" + acct + ".tsv");
            var prices = LoadPrices(pricesPath);
            var cache = new Dictionary<string, Price>();
            var days = new Dictionary<string, double>();
            var models = new Dictionary<string, double>();
            var projects = new Dictionary<string, double>();
            string today = now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            string month = now.ToString("yyyy-MM", CultureInfo.InvariantCulture);
            string from = now.Date.AddDays(-13).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (File.Exists(usageF)) {
                foreach (string l in File.ReadLines(usageF)) {
                    string[] a = l.Split('\t');
                    if (a.Length < 9 || a[0].Length < 13) continue;
                    string day = a[0].Substring(0, 10);
                    bool inMonth = a[0].StartsWith(month, StringComparison.Ordinal);
                    if (!inMonth && string.CompareOrdinal(day, from) < 0) continue;
                    Price p;
                    string ck = a[1] + "|" + a[2];
                    if (!cache.TryGetValue(ck, out p)) { p = FindPrice(prices, a[2], a[1]); cache[ck] = p; }
                    double inp = double.Parse(a[4], CultureInfo.InvariantCulture), outp = double.Parse(a[5], CultureInfo.InvariantCulture);
                    double w5 = double.Parse(a[6], CultureInfo.InvariantCulture), w1 = double.Parse(a[7], CultureInfo.InvariantCulture), cr = double.Parse(a[8], CultureInfo.InvariantCulture);
                    double cost = (inp * p.In + outp * p.Out + cr * p.Read + w5 * p.W5 + w1 * p.W1) / 1e6;
                    if (string.CompareOrdinal(day, from) >= 0) { double v; days.TryGetValue(day, out v); days[day] = v + cost; }
                    if (inMonth) {
                        sum.MonthCost += cost; sum.MonthTokens += inp + outp + w5 + w1 + cr; sum.MonthRequests += 1;
                        string pm = PrettyModel(a[2]); double v2; models.TryGetValue(pm, out v2); models[pm] = v2 + cost;
                        double v3; projects.TryGetValue(a[3], out v3); projects[a[3]] = v3 + cost;
                    }
                    if (day == today) {
                        sum.TodayCost += cost;
                        int hr; if (int.TryParse(a[0].Substring(11, 2), out hr) && hr >= 0 && hr < 24) sum.Hours[hr] += cost;
                    }
                }
            }
            for (int i = 13; i >= 0; i--) {
                string d = now.Date.AddDays(-i).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                double v; days.TryGetValue(d, out v);
                sum.Days.Add(new KeyValuePair<string, double>(d, v));
            }
            var ml = new List<KeyValuePair<string, double>>(models); ml.Sort((x, y) => y.Value.CompareTo(x.Value)); sum.Models = ml;
            var pl = new List<KeyValuePair<string, double>>(projects); pl.Sort((x, y) => y.Value.CompareTo(x.Value)); sum.Projects = pl;
            return sum;
        }
    }
}
'@

Add-Type -Namespace AILimits -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wp, IntPtr lp);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@

[void][AILimits.Native]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:scale = $g0.DpiX / 96.0
$g0.Dispose()
function S([double]$v) { [int][math]::Round($v * $script:scale) }

# ---------- design tokens (rounded cards, bold numerals, round icon buttons, lime / orange / red accents) ----------
function New-Rgb([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
# "Instrument" look: off-white frosted panel (90% opaque) over a blurred backdrop, black ink,
# hairline dividers instead of cards, graduated meters; colour only for warnings.
$Glass = @{
    Card = (New-Rgb '#FAFAF8'); Opacity = 230
    Primary = (New-Rgb '#121212'); Secondary = (New-Rgb '#55554F'); Faint = (New-Rgb '#6B6B66')
    Chip = [System.Drawing.Color]::Transparent; ChipHover = (New-Rgb '#ECEBE7'); IconFg = (New-Rgb '#121212')
    Track = (New-Rgb '#DAD9D3'); Tick = (New-Rgb '#A3A29C'); Rule = (New-Rgb '#E3E2DD'); Dash = (New-Rgb '#D6D5D0')
    Border = [System.Drawing.Color]::FromArgb(40, 0, 0, 0)
    Ink = (New-Rgb '#121212'); Ok = (New-Rgb '#2F7D4F'); Warn = (New-Rgb '#D9480F'); Bad = (New-Rgb '#C1121F')
    OkFg = (New-Rgb '#2F6B45'); WarnFg = (New-Rgb '#B33C0C'); BadFg = (New-Rgb '#B42318')
}
$Radius = @{ Card = 12; Compact = 10; Btn = 6 }

function New-PxFont([string]$family, [double]$px, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
    New-Object System.Drawing.Font($family, [single](S $px), $style, [System.Drawing.GraphicsUnit]::Pixel)
}
function Test-FontFamily([string]$name) {
    try { $ff = New-Object System.Drawing.FontFamily($name); $ff.Dispose(); return $true } catch { return $false }
}
$IconFamily = $null
foreach ($cand in 'Segoe Fluent Icons', 'Segoe MDL2 Assets') { if (-not $IconFamily -and (Test-FontFamily $cand)) { $IconFamily = $cand } }
# Bahnschrift (DIN-style, ships with Windows 10/11) for names and numbers, Cascadia Mono / Consolas for times.
function Get-FirstFont([string[]]$names) { foreach ($n in $names) { if (Test-FontFamily $n) { return $n } }; 'Segoe UI' }
$FontNum = Get-FirstFont @('Bahnschrift', 'Segoe UI')
$FontNumSemi = Get-FirstFont @('Bahnschrift SemiBold', 'Segoe UI Semibold')
$FontMono = Get-FirstFont @('Cascadia Mono', 'Consolas')
$FontUi = 'Segoe UI'
$Fonts = @{
    Title = New-PxFont $FontNumSemi 12
    Name  = New-PxFont $FontNumSemi 14
    Plan  = New-PxFont $FontNum 14
    Big   = New-PxFont $FontNum 40
    BigUnit = New-PxFont $FontNum 16
    Money = New-PxFont $FontNum 22
    Unit  = New-PxFont $FontUi 12
    Label = New-PxFont $FontUi 12
    Small = New-PxFont $FontUi 11
    Value = New-PxFont $FontNumSemi 13
    Mono  = New-PxFont $FontMono 11
    MonoV = New-PxFont $FontMono 12
    Note  = New-PxFont $FontUi 11
}
if ($IconFamily) {
    $Fonts.Icon = New-PxFont $IconFamily 13
    $Glyph = @{ refresh = [string][char]0xE72C; settings = [string][char]0xE713; hide = [string][char]0xE921 }
} else {
    $Fonts.Icon = New-PxFont 'Segoe UI Symbol' 14
    $Glyph = @{ refresh = [string][char]0x21BB; settings = [string][char]0x2699; hide = [string][char]0x2013 }
}

# dialogs (settings, wizard, confirmations) follow the same rules
$DlgColors = @{
    Bg = (New-Rgb '#FAFAF8'); Side = (New-Rgb '#F3F2EE'); Text = (New-Rgb '#121212'); Muted = (New-Rgb '#55554F'); Faint = (New-Rgb '#6B6B66')
    Field = (New-Rgb '#FFFFFF'); FieldBorder = (New-Rgb '#D6D5D0'); Rule = (New-Rgb '#E3E2DD')
    Chip = (New-Rgb '#FFFFFF'); ChipHover = (New-Rgb '#F0EFEB'); Dark = (New-Rgb '#121212'); DarkHover = (New-Rgb '#33332F')
    Accent = (New-Rgb '#121212'); Danger = (New-Rgb '#B42318'); Ok = (New-Rgb '#2F6B45'); Warn = (New-Rgb '#B33C0C')
}
$DlgFonts = @{
    Body = New-Object System.Drawing.Font($FontUi, 9.75)
    Small = New-Object System.Drawing.Font($FontUi, 8.25)
    Btn = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    H1 = New-Object System.Drawing.Font($FontNumSemi, 15)
    Caps = New-Object System.Drawing.Font('Segoe UI Semibold', 7.5)
    Mono = New-Object System.Drawing.Font($FontMono, 9)
}

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [math]::Min($r, [math]::Min($w, $h) / 2)
    if ($r -le 0) { $p.AddRectangle((New-Object System.Drawing.RectangleF($x, $y, $w, $h))); return $p }
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

function Set-ButtonStyle($b, [string]$kind = 'secondary') {
    $b.Font = $DlgFonts.Btn
    $bc = [System.Drawing.Color]::Empty
    switch ($kind) {
        'primary' { $b.BackColor = $DlgColors.Dark; $b.ForeColor = [System.Drawing.Color]::White; $hc = $DlgColors.DarkHover }
        'accent'  { $b.BackColor = $DlgColors.Dark; $b.ForeColor = [System.Drawing.Color]::White; $hc = $DlgColors.DarkHover }
        'danger'  { $b.BackColor = $DlgColors.Bg; $b.ForeColor = $DlgColors.Danger; $hc = (New-Rgb '#FBEDEB') }
        'ghost'   { $b.BackColor = $DlgColors.Bg; $b.ForeColor = $DlgColors.Text; $hc = $DlgColors.ChipHover }
        default   { $b.BackColor = $DlgColors.Chip; $b.ForeColor = $DlgColors.Text; $hc = $DlgColors.ChipHover; $bc = $DlgColors.FieldBorder }
    }
    if ($b -is [AILimitsUI.RoundButton]) { $b.HoverColor = $hc; $b.BorderColor = $bc; $b.Radius = [single](S $Radius.Btn) }
    else { $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $DlgColors.FieldBorder }
}

function Set-MenuStyle($m) {
    $m.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object AILimitsUI.FlatColors))
    $m.Font = $DlgFonts.Body
    $m.BackColor = $DlgColors.Bg
    $m.ForeColor = $DlgColors.Text
}

function Set-DialogStyle($f, $primary = @(), $accent = @()) {
    $f.BackColor = $DlgColors.Bg
    $f.ForeColor = $DlgColors.Text
    $f.Font = $DlgFonts.Body
    $stack = New-Object System.Collections.Stack
    foreach ($c0 in $f.Controls) { $stack.Push($c0) }
    while ($stack.Count) {
        $ctl = $stack.Pop()
        foreach ($c1 in $ctl.Controls) { $stack.Push($c1) }
        if ($ctl -is [System.Windows.Forms.Button]) {
            if ($primary -contains $ctl) { Set-ButtonStyle $ctl 'primary' }
            elseif ($accent -contains $ctl) { Set-ButtonStyle $ctl 'accent' }
            elseif ($ctl.AccessibleDescription -in 'danger', 'ghost') { Set-ButtonStyle $ctl $ctl.AccessibleDescription }
            else { Set-ButtonStyle $ctl 'secondary' }
            $ctl.BackColor = $(if ($ctl.ForeColor -eq [System.Drawing.Color]::White) { $DlgColors.Dark } elseif ($ctl.AccessibleDescription -in 'danger', 'ghost') { $ctl.Parent.BackColor } else { $DlgColors.Chip })
        } elseif ($ctl -is [System.Windows.Forms.ComboBox]) {
            $ctl.FlatStyle = 'Flat'
            $ctl.BackColor = $DlgColors.Field
            $ctl.ForeColor = $DlgColors.Text
        } elseif ($ctl -is [System.Windows.Forms.CheckBox]) {
            $ctl.FlatStyle = 'Flat'
            $ctl.FlatAppearance.BorderColor = $DlgColors.FieldBorder
            $ctl.FlatAppearance.CheckedBackColor = $DlgColors.Field
            $ctl.FlatAppearance.MouseOverBackColor = $DlgColors.ChipHover
            $ctl.ForeColor = $DlgColors.Text
            $ctl.Cursor = 'Hand'
        } elseif ($ctl -is [System.Windows.Forms.TextBox] -or $ctl -is [System.Windows.Forms.ListBox] -or $ctl -is [System.Windows.Forms.NumericUpDown]) {
            if ([string]$ctl.BorderStyle -eq 'None') { continue }
            $ctl.BorderStyle = 'FixedSingle'
            $ctl.BackColor = $DlgColors.Field
        }
    }
}

# ---------- service types ----------
$Types = [ordered]@{
    'claude-code' = @{
        Title = 'Claude — subscription (via Claude Code sign-in)'; Default = 'Claude'
        Fields = @('configDir', 'planPrice', 'autoRefresh', 'acct'); KeyLabel = 'Token (optional)'
        Hint = 'Limits are shared by Claude Code, the desktop app and the website. Sources, in order: the Claude Code bridge in the terminal → claude.ai (if a session key is set) → the Claude Code sign-in (%USERPROFILE%\.claude\.credentials.json). Sign in once: run claude in a terminal, then /login. The Token field can stay empty.'
    }
    'claude-web' = @{
        Title = 'Claude — subscription (via claude.ai cookie)'; Default = 'Claude'
        Fields = @('key'); KeyLabel = 'sessionKey'
        Hint = 'For when Claude Code is not installed. Open claude.ai in a browser → F12 → Application → Cookies → claude.ai → copy the sessionKey value (starts with sk-ant-sid). It lasts about a month.'
    }
    'codex' = @{
        Title = 'ChatGPT — subscription (via Codex CLI sign-in)'; Default = 'ChatGPT'
        Fields = @('configDir', 'planPrice', 'acct'); KeyLabel = 'Key'
        Hint = 'Uses the Codex CLI sign-in on this computer (%USERPROFILE%\.codex\auth.json) and shows the Codex limits of your ChatGPT plan. The "Connect automatically…" button helps you install it and sign in.'
    }
    'gemini' = @{
        Title = 'Gemini — Gemini CLI quotas (beta)'; Default = 'Gemini'
        Fields = @(); KeyLabel = 'Key'
        Hint = 'Uses the Gemini CLI sign-in (%USERPROFILE%\.gemini\oauth_creds.json) and shows the remaining quota per model. Relies on an unofficial Google endpoint, so it may break. The "Connect automatically…" button helps you install it and sign in.'
    }
    'anthropic-api' = @{
        Title = 'Anthropic API — monthly spend'; Default = 'Anthropic API'
        Fields = @('key', 'budget', 'cents'); KeyLabel = 'Admin key'
        Hint = 'Needs an Admin key (sk-ant-admin…): Console → Settings → Admin keys. Anthropic does not expose the prepaid credit balance via API, so set a monthly budget and the widget shows how much of it is left.'
    }
    'openai-api' = @{
        Title = 'OpenAI API — monthly spend'; Default = 'OpenAI API'
        Fields = @('key', 'budget'); KeyLabel = 'Admin key'
        Hint = 'Needs an Admin key (sk-admin…): platform.openai.com → Settings → Organization → Admin keys. OpenAI does not expose the credit balance via API, so set a monthly budget.'
    }
    'openrouter' = @{
        Title = 'OpenRouter — balance'; Default = 'OpenRouter'
        Fields = @('key'); KeyLabel = 'API key'
        Hint = 'A key from openrouter.ai/settings/keys. A management key shows the whole account balance; a regular key shows that key''s limit and spend.'
    }
    'deepseek' = @{
        Title = 'DeepSeek — balance'; Default = 'DeepSeek'
        Fields = @('key'); KeyLabel = 'API key'
        Hint = 'A regular API key from platform.deepseek.com → API keys.'
    }
    'custom' = @{
        Title = 'Other service (custom URL)'; Default = 'My service'
        Fields = @('key', 'url', 'header', 'valuePath', 'totalPath', 'unit'); KeyLabel = 'Key'
        Hint = 'Any API that returns the balance as JSON. Example for Moonshot (Kimi): URL https://api.moonshot.ai/v1/users/me/balance, value path data.available_balance. Use dots for nesting and list[0] for array items.'
    }
}

# ---------- config ----------
function Protect-Text([string]$t) {
    if (-not $t) { return '' }
    ConvertTo-SecureString $t -AsPlainText -Force | ConvertFrom-SecureString
}
function Unprotect-Text([string]$t) {
    if (-not $t) { return '' }
    try {
        $ss = ConvertTo-SecureString $t
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } catch { '' }
}
function New-Provider([string]$type) {
    [ordered]@{
        id = [guid]::NewGuid().ToString('N').Substring(0, 8); type = $type; name = $Types[$type].Default
        key = ''; webKey = ''; budget = ''; url = ''; header = 'Authorization: Bearer {key}'
        valuePath = ''; totalPath = ''; unit = '$'; cents = $true
        configDir = ''; profile = ''; planPrice = ''
    }
}

# Each Claude account gets its own browser profile; the first one keeps the original 'browser' folder.
function Set-DefaultProfile($prov, $list) {
    if ($prov.type -ne 'claude-code' -or $prov.profile) { return }
    $taken = $false
    foreach ($o in @($list)) { if (-not [object]::ReferenceEquals($o, $prov) -and $o.type -eq 'claude-code' -and (([string]$o.profile) -eq 'browser' -or -not $o.profile)) { $taken = $true } }
    if ($taken) { $prov['profile'] = 'browser-' + $prov.id } else { $prov['profile'] = 'browser' }
}
function Load-Config {
    $cfg = [ordered]@{ interval = 5; x = -1; y = -1; theme = 'dark'; providers = New-Object System.Collections.ArrayList }
    if (Test-Path $CfgPath) {
        try {
            $j = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.interval) { $cfg.interval = [int]$j.interval }
            if ($j.theme -eq 'light') { $cfg.theme = 'light' }
            if ($j.textMode) { $cfg['textMode'] = [string]$j.textMode }
            if ($null -ne $j.x) { $cfg.x = [int]$j.x; $cfg.y = [int]$j.y }
            foreach ($p in @($j.providers)) {
                if (-not $p -or -not $Types.Contains([string]$p.type)) { continue }
                $h = New-Provider ([string]$p.type)
                foreach ($pr in $p.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
                [void]$cfg.providers.Add($h)
            }
            foreach ($h in $cfg.providers) { Set-DefaultProfile $h $cfg.providers }
            foreach ($k in 'hotkey', 'autoHide', 'compact', 'launcherVersion', 'shortcutsMade') { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } }
        } catch { Write-Log "config: $_" }
    } else {
        $first = New-Provider 'claude-code'
        $first['profile'] = 'browser'
        [void]$cfg.providers.Add($first)
    }
    if (-not $cfg.Contains('hotkey')) { $cfg['hotkey'] = 'Ctrl+Alt+L' }
    if (-not $cfg.Contains('autoHide')) { $cfg['autoHide'] = $true }
    if (-not $cfg.Contains('compact')) { $cfg['compact'] = $false }
    $cfg
}
function Save-Config {
    try { $script:cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $CfgPath -Encoding UTF8 } catch { Write-Log "save: $_" }
}
function Set-Autostart([bool]$on) {
    if ($on) {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($StartupLnk)
        if (Test-Path $ExePath) {
            $sc.TargetPath = $ExePath
            $sc.Arguments = ''
            $sc.IconLocation = $ExePath + ',0'
        } else {
            $sc.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $ScriptDir 'AILimits.ps1') + '"'
            $sc.WindowStyle = 7
        }
        $sc.WorkingDirectory = $ScriptDir
        $sc.Save()
    } elseif (Test-Path $StartupLnk) {
        Remove-Item $StartupLnk -Force
    }
}

# ---------- launcher: "AI Limits.exe" (replaces the VBScript launcher) ----------
# Built on this PC by the C# compiler that ships with Windows, so there is nothing to download.
$LauncherVersion = 2
$ExePath = Join-Path $ScriptDir 'AI Limits.exe'
$IcoPath = Join-Path $AppDir 'ailimits.ico'
$LauncherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
[assembly: AssemblyTitle("AI Limits")]
[assembly: AssemblyProduct("AI Limits")]
[assembly: AssemblyVersion("2.0.0.0")]
static class Launcher {
    [STAThread]
    static void Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "AILimits.ps1");
        if (!File.Exists(script)) { MessageBox.Show("AILimits.ps1 must be in the same folder as AI Limits.exe.", "AI Limits"); return; }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
'@

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $s1 = [single]$size
    $bg = New-Object System.Drawing.SolidBrush((New-Rgb '#121212'))
    $path = New-RoundPath 0 0 $s1 $s1 ($s1 * 0.24)
    $g.FillPath($bg, $path)
    # three rising bars: two off-white, the tallest in signal orange
    $bw = $s1 * 0.16; $gap = $s1 * 0.07; $x = ($s1 - (3 * $bw + 2 * $gap)) / 2; $base = $s1 * 0.78
    $cols = @((New-Rgb '#FAFAF8'), (New-Rgb '#FAFAF8'), (New-Rgb '#D9480F'))
    $hs = @(0.30, 0.45, 0.58)
    for ($i = 0; $i -lt 3; $i++) {
        $h = $s1 * $hs[$i]
        $br = New-Object System.Drawing.SolidBrush($cols[$i])
        $bp = New-RoundPath ($x + $i * ($bw + $gap)) ($base - $h) $bw $h ($bw / 2)
        $g.FillPath($br, $bp)
        $br.Dispose(); $bp.Dispose()
    }
    $bg.Dispose(); $path.Dispose(); $g.Dispose()
    $bmp
}

# One icon frame in classic DIB form (32-bit BGRA, bottom-up, empty AND mask): accepted by every icon reader and by csc.
function Get-IconDib([int]$size) {
    $bmp = New-IconBitmap $size
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $raw = New-Object byte[] ($stride * $size)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($data); $bmp.Dispose()
    $maskRow = [int]([math]::Floor(($size + 31) / 32) * 4)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([uint32]40); $w.Write([int32]$size); $w.Write([int32]($size * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]($size * $size * 4 + $maskRow * $size)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $size - 1; $y -ge 0; $y--) { $w.Write($raw, $y * $stride, $size * 4) }
    $w.Write((New-Object byte[] ($maskRow * $size)))
    $w.Flush()
    , $ms.ToArray()
}

function New-AppIcon {
    $sizes = @(16, 24, 32, 48, 256)
    $frames = @(); foreach ($sz in $sizes) { $frames += , (Get-IconDib $sz) }
    $fs = [System.IO.File]::Create($IcoPath)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $d = $sizes[$i]; if ($d -ge 256) { $d = 0 }
        $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$frames[$i].Length); $bw.Write([uint32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($fr in $frames) { $bw.Write([byte[]]$fr) }
    $bw.Close(); $fs.Close()
}

function Build-Launcher([bool]$force = $false) {
    if (-not $force -and (Test-Path $ExePath) -and ([int]$script:cfg.launcherVersion -eq $LauncherVersion)) { return $true }
    try {
        $iconOk = $true
        try { New-AppIcon } catch { $iconOk = $false; Write-Log "icon: $_" }
        $prov = New-Object Microsoft.CSharp.CSharpCodeProvider
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true
        $cp.GenerateInMemory = $false
        $cp.OutputAssembly = $ExePath
        $cp.CompilerOptions = '/target:winexe /optimize'
        if ($iconOk) { $cp.CompilerOptions += ' /win32icon:"' + $IcoPath + '"' }
        [void]$cp.ReferencedAssemblies.Add('System.dll')
        [void]$cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')
        $res = $prov.CompileAssemblyFromSource($cp, $LauncherSource)
        if ($res.Errors.HasErrors -and $iconOk) {
            Write-Log ('launcher with icon: ' + ((@($res.Errors) | ForEach-Object { $_.ToString() }) -join ' | '))
            $cp.CompilerOptions = '/target:winexe /optimize'
            $res = $prov.CompileAssemblyFromSource($cp, $LauncherSource)
        }
        if ($res.Errors.HasErrors) {
            Write-Log ('launcher: ' + ((@($res.Errors) | ForEach-Object { $_.ToString() }) -join ' | '))
            return $false
        }
        $script:cfg['launcherVersion'] = $LauncherVersion
        Save-Config
        return $true
    } catch {
        Write-Log "launcher: $_"
        return $false
    }
}

function New-AppShortcut([string]$lnk) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $ExePath
    $sc.WorkingDirectory = $ScriptDir
    $sc.IconLocation = $ExePath + ',0'
    $sc.Description = 'AI usage limits widget'
    $sc.Save()
}

# First run: Start menu + desktop shortcuts, autostart moved to the exe, old VBScript launcher removed.
function Install-Launcher {
    if (-not (Build-Launcher $false)) { return }
    try {
        if (-not $script:cfg.shortcutsMade) {
            New-AppShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'AI Limits.lnk')
            New-AppShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Limits.lnk')
            $script:cfg['shortcutsMade'] = $true
            Save-Config
        }
        if (Test-Path $StartupLnk) { Set-Autostart $true }
        $vbs = Join-Path $ScriptDir 'Start AI Limits.vbs'
        if (Test-Path $vbs) { Remove-Item $vbs -Force -ErrorAction SilentlyContinue }
    } catch { Write-Log "shortcuts: $_" }
}

# ---------- shared code: read the claude.ai key from a separate browser profile (Chrome DevTools Protocol) ----------
$CdpCode = @'
function Get-FreePort {
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $l.Start(); $pt = $l.LocalEndpoint.Port; $l.Stop()
    $pt
}
function Find-Browser {
    $cands = @()
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($base) { $cands += (Join-Path $base 'Microsoft\Edge\Application\msedge.exe'); $cands += (Join-Path $base 'Google\Chrome\Application\chrome.exe') }
    }
    if ($env:LOCALAPPDATA) { $cands += (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe') }
    foreach ($x in $cands) { if (Test-Path $x) { return $x } }
    $null
}
function Get-CdpWsUrl([int]$port) {
    try { return (Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 2 -UseBasicParsing).webSocketDebuggerUrl } catch { return $null }
}
function Invoke-Cdp([string]$wsUrl, [string]$method, $params, [int]$timeout = 10000) {
    if ($null -eq $params) { $params = @{} }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [Threading.CancellationToken]::None
    try {
        if (-not $ws.ConnectAsync([uri]$wsUrl, $ct).Wait(5000)) { throw 'CDP: no connection' }
        $msg = @{ id = 1; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 5
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        [void]$ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(5000)
        $buf = New-Object byte[] 65536
        for ($n = 0; $n -lt 20; $n++) {
            $ms = New-Object IO.MemoryStream
            do {
                $t = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $ct)
                if (-not $t.Wait($timeout)) { throw 'CDP: no response' }
                $res = $t.Result
                $ms.Write($buf, 0, $res.Count)
            } while (-not $res.EndOfMessage)
            $obj = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
            if ($obj.id -eq 1) { return $obj }
        }
        return $null
    } finally { $ws.Dispose() }
}
function Get-CdpSessionKey([string]$wsUrl) {
    $r = Invoke-Cdp $wsUrl 'Storage.getCookies' @{}
    foreach ($ck in @($r.result.cookies)) {
        if ($ck.name -eq 'sessionKey' -and ([string]$ck.domain) -like '*claude.ai') { return [string]$ck.value }
    }
    $null
}
function Close-CdpBrowser([string]$wsUrl) { try { [void](Invoke-Cdp $wsUrl 'Browser.close' @{}) } catch {} }
function Get-BrowserUA([string]$exe) {
    $ver = '131.0.0.0'
    try { $v = (Get-Item $exe).VersionInfo.ProductVersion; if ($v) { $ver = $v } } catch {}
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$ver Safari/537.36"
    if ($exe -like '*msedge*') { $ua += " Edg/$ver" }
    $ua
}

function Close-ProfileBrowser {
    # closes a background browser that AI Limits may have left running on its profile
    $pf = Join-Path $env:APPDATA 'AILimits\browser-port.txt'
    if (-not (Test-Path $pf)) { return }
    try { $u = Get-CdpWsUrl ([int](Get-Content $pf -Raw).Trim()); if ($u) { Close-CdpBrowser $u; Start-Sleep -Milliseconds 800 } } catch {}
    Remove-Item $pf -Force -ErrorAction SilentlyContinue
}

# Opens claude.ai in a real browser (the AI Limits profile, where you are signed in) and asks for the usage from inside the page.
function Get-ClaudeUsageViaBrowser([string]$profileDir) {
    $exe = Find-Browser
    if (-not $exe) { throw 'Edge or Chrome not found' }
    $modeF = Join-Path $env:APPDATA 'AILimits\browser-mode.txt'
    $modes = @('headless', 'offscreen')
    if ((Test-Path $modeF) -and ((Get-Content $modeF -Raw).Trim() -eq 'offscreen')) { $modes = @('offscreen') }
    $lastErr = $null
    foreach ($mode in $modes) {
        Close-ProfileBrowser
        $port = Get-FreePort
        $argList = @(('--user-data-dir="' + $profileDir + '"'), "--remote-debugging-port=$port", '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--mute-audio')
        if ($mode -eq 'headless') { $argList += @('--headless=new', ('--user-agent="' + (Get-BrowserUA $exe) + '"'), '--window-size=1280,800') }
        else { $argList += @('--window-position=-32000,-32000', '--window-size=800,600') }
        $argList += 'about:blank'
        Set-Content -Path (Join-Path $env:APPDATA 'AILimits\browser-port.txt') -Value $port
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden
        try {
            $bws = $null
            for ($i = 0; $i -lt 30 -and -not $bws; $i++) { Start-Sleep -Milliseconds 500; $bws = Get-CdpWsUrl $port }
            if (-not $bws) { throw 'the background browser did not start' }
            try { $tg = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$port/json/new?https://claude.ai/" -TimeoutSec 10 -UseBasicParsing }
            catch { $tg = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/new?https://claude.ai/" -TimeoutSec 10 -UseBasicParsing }
            $pws = $tg.webSocketDebuggerUrl
            $ready = $false
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 750
                try {
                    $st = Invoke-Cdp $pws 'Runtime.evaluate' @{ expression = 'document.readyState + "|" + document.title + "|" + location.host'; returnByValue = $true }
                    $v = [string]$st.result.result.value
                    if ($v -like 'complete|*claude.ai' -and $v -notmatch 'Just a moment|Checking|Attention Required|moment') { $ready = $true; break }
                } catch {}
            }
            if (-not $ready) { throw 'CF' }
            $js = @"
(async () => {
  const r1 = await fetch('/api/organizations', { credentials: 'include' });
  if (!r1.ok) return JSON.stringify({ status: r1.status, body: '' });
  const orgs = await r1.json();
  const org = orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0];
  if (!org) return JSON.stringify({ status: 404, body: '' });
  const r2 = await fetch('/api/organizations/' + org.uuid + '/usage', { credentials: 'include' });
  return JSON.stringify({ status: r2.status, body: await r2.text() });
})()
"@
            $ev = Invoke-Cdp $pws 'Runtime.evaluate' @{ expression = $js; awaitPromise = $true; returnByValue = $true } 30000
            $o = ([string]$ev.result.result.value) | ConvertFrom-Json
            if ($o.status -eq 401 -or $o.status -eq 403) { throw 'NOT_SIGNED_IN' }
            if ($o.status -ne 200) { throw ('claude.ai answered ' + $o.status) }
            if ($mode -eq 'offscreen') { Set-Content -Path $modeF -Value 'offscreen' }
            return ($o.body | ConvertFrom-Json)
        } catch {
            $lastErr = $_.Exception.Message
            if ($lastErr -ne 'CF') { break }
        } finally {
            $u = Get-CdpWsUrl $port
            if ($u) { Close-CdpBrowser $u }
            Start-Sleep -Milliseconds 800
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
            Remove-Item (Join-Path $env:APPDATA 'AILimits\browser-port.txt') -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lastErr -eq 'CF') { throw 'claude.ai did not open in the background browser (Cloudflare check)' }
    throw $lastErr
}

function Get-SessionKeyHeadless([string]$profileDir) {
    $exe = Find-Browser
    if (-not $exe -or -not (Test-Path $profileDir)) { return $null }
    $port = Get-FreePort
    $argList = @('--headless=new', ('--user-data-dir="' + $profileDir + '"'), "--remote-debugging-port=$port", '--no-first-run', 'about:blank')
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden
    $key = $null
    try {
        $wsUrl = $null
        for ($i = 0; $i -lt 30 -and -not $wsUrl; $i++) { Start-Sleep -Milliseconds 500; $wsUrl = Get-CdpWsUrl $port }
        if ($wsUrl) { $key = Get-CdpSessionKey $wsUrl; Close-CdpBrowser $wsUrl }
    } catch {
    } finally {
        Start-Sleep -Milliseconds 800
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
    }
    $key
}
'@
. ([scriptblock]::Create($CdpCode))

# ---------- service requests (run in the background so the window never freezes) ----------
$FetchScript = @'
param($providers, $cdpCode)
$ErrorActionPreference = 'Stop'
. ([scriptblock]::Create($cdpCode))
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Inv = [Globalization.CultureInfo]::InvariantCulture

function To-Num($v) { [double]::Parse(([string]$v).Trim(), $Inv) }

function New-Line($label, $pct, $text, $warn = $false, $reset = $null) {
    [pscustomobject]@{ Label = $label; Pct = $pct; Text = $text; Warn = $warn; Reset = $reset }
}

function Test-CfBlock($err) {
    # claude.ai answers with an HTML challenge page when Cloudflare blocks a non-browser request
    try {
        $resp = $err.Exception.Response
        if ($resp.Headers['cf-mitigated']) { return $true }
        return ([string]$resp.ContentType -like 'text/html*')
    } catch { return $false }
}

function Test-ClaudeCodeRunning {
    try {
        if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) { return $true }
        $nodes = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
        foreach ($n in @($nodes)) { if ([string]$n.CommandLine -match 'claude') { return $true } }
    } catch {}
    $false
}

# Same refresh Claude Code does itself; the rotated tokens are written back so Claude Code keeps working.
function Update-ClaudeCodeToken([string]$credPath) {
    $raw = Get-Content $credPath -Raw -Encoding UTF8
    $j = $raw | ConvertFrom-Json
    $rt = [string]$j.claudeAiOauth.refreshToken
    if (-not $rt) { return $null }
    $body = @{ grant_type = 'refresh_token'; refresh_token = $rt; client_id = '9d1c250a-e61b-44d9-88ed-5944d1962f5e' } | ConvertTo-Json -Compress
    $tr = Invoke-RestMethod -Uri 'https://platform.claude.com/v1/oauth/token' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' -TimeoutSec 20 -UseBasicParsing -UserAgent 'claude-code/2.1.0'
    if (-not $tr.access_token) { return $null }
    Copy-Item $credPath ($credPath + '.ailimits-backup') -Force
    $j.claudeAiOauth.accessToken = [string]$tr.access_token
    if ($tr.refresh_token) { $j.claudeAiOauth.refreshToken = [string]$tr.refresh_token }
    if ($tr.expires_in) { $j.claudeAiOauth.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([double]$tr.expires_in).ToUnixTimeMilliseconds() }
    $tmp = $credPath + '.tmp'
    [IO.File]::WriteAllText($tmp, ($j | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $credPath -Force
    [string]$tr.access_token
}

function Get-Code($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return $null }
}

function Get-ErrText($err) {
    $code = Get-Code $err
    if ($code -eq 401 -or $code -eq 403) { return "Error $code — the key was rejected or lacks permissions" }
    if ($code -eq 429) { return 'Error 429 — too many requests, will retry later' }
    if ($code) { return "HTTP error $code" }
    $err.Exception.Message
}

function Invoke-JsonPost($url, $headers, $bodyObj, $ua = 'AILimits/1.0') {
    $json = $bodyObj | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json' -TimeoutSec 20 -UserAgent $ua -UseBasicParsing
}

function Get-GeminiClient {
    $cache = Join-Path $env:APPDATA 'AILimits\gemini-client.json'
    if (Test-Path $cache) {
        try { $c0 = Get-Content $cache -Raw | ConvertFrom-Json; if ($c0.id -and $c0.secret) { return $c0 } } catch {}
    }
    $root = Join-Path $env:APPDATA 'npm\node_modules\@google\gemini-cli'
    if (-not (Test-Path $root)) { return $null }
    $files = @()
    foreach ($cand in @('bundle\gemini.js', 'node_modules\@google\gemini-cli-core\dist\src\code_assist\oauth2.js')) {
        $fp = Join-Path $root $cand
        if (Test-Path $fp) { $files += $fp }
    }
    $g = Join-Path $root 'node_modules\@google'
    if (-not $files -and (Test-Path $g)) {
        $files = @(Get-ChildItem -Path $g -Recurse -File -Filter 'oauth2.js' -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object { $_.FullName })
    }
    foreach ($fp in $files) {
        $txt = [IO.File]::ReadAllText($fp)
        $m1 = [regex]::Match($txt, '\d+-[a-z0-9]+\.apps\.googleusercontent\.com')
        $m2 = [regex]::Match($txt, 'GOCSPX-[A-Za-z0-9_\-]+')
        if ($m1.Success -and $m2.Success) {
            $res = [pscustomobject]@{ id = $m1.Value; secret = $m2.Value }
            try { $res | ConvertTo-Json | Set-Content $cache -Encoding UTF8 } catch {}
            return $res
        }
    }
    $null
}

function Invoke-Json($url, $headers, $ua = 'AILimits/1.0') {
    Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 20 -UserAgent $ua -UseBasicParsing
}

function Get-JsonPath($obj, [string]$path) {
    $cur = $obj
    foreach ($part in $path.Trim().Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($part -match '^(.*)\[(\d+)\]$') {
            $nm = $matches[1]; $ix = [int]$matches[2]
            if ($nm) { $cur = $cur.$nm }
            $cur = @($cur)[$ix]
        } else {
            $cur = $cur.$part
        }
    }
    $cur
}

function Get-ResetTime($iso) {
    if ($null -eq $iso -or $iso -eq '') { return $null }
    try {
        if ($iso -is [datetime]) { return [DateTimeOffset]::new($iso.ToUniversalTime()) }
        if ($iso -is [ValueType]) { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$iso) }
        return [DateTimeOffset]::Parse([string]$iso, $Inv)
    } catch { return $null }
}

function Format-Ago([int64]$secs) {
    if ($secs -lt 60) { return 'just now' }
    if ($secs -lt 3600) { return ('{0} min ago' -f [int][math]::Floor($secs / 60)) }
    '{0} h {1} min ago' -f [int][math]::Floor($secs / 3600), [int][math]::Floor(($secs % 3600) / 60)
}

function Format-Reset($iso) {
    $t = Get-ResetTime $iso
    if ($null -eq $t) { return '' }
    $d = $t - [DateTimeOffset]::Now
    if ($d.TotalMinutes -lt 1) { return 'now' }
    if ($d.TotalHours -ge 24) { return ('{0}d {1}h' -f [int][math]::Floor($d.TotalDays), $d.Hours) }
    if ($d.TotalHours -ge 1) { return ('{0}h {1}m' -f [int][math]::Floor($d.TotalHours), $d.Minutes) }
    '{0}m' -f $d.Minutes
}

function Convert-ClaudeUsage($r) {
    $labels = @{
        five_hour = '5-hour limit'; seven_day = 'Weekly'; seven_day_opus = 'Weekly · Opus'
        seven_day_sonnet = 'Weekly · Sonnet'; seven_day_oauth_apps = 'Weekly · apps'
        seven_day_cowork = 'Weekly · Cowork'; extra_usage = 'Extra usage'; spend_limit = 'Spend limit'
    }
    $lines = @(); $main = $null
    foreach ($prop in $r.PSObject.Properties) {
        $v = $prop.Value
        if ($null -eq $v) { continue }
        if ($null -eq $v.PSObject.Properties['utilization']) { continue }
        if ($null -eq $v.utilization) { continue }
        $pct = [double]$v.utilization
        $rt = Get-ResetTime $v.resets_at
        if ($null -ne $rt -and $rt -lt [DateTimeOffset]::Now) { $pct = 0 }
        if ($labels.ContainsKey($prop.Name)) { $label = $labels[$prop.Name] } else { $label = $prop.Name -replace '_', ' ' }
        $text = '{0}%' -f [math]::Round($pct)
        $reset = Format-Reset $v.resets_at
        if ($reset) { $text += ' · resets in ' + $reset } else { $reset = $null }
        $lines += New-Line $label $pct $text $false $reset
        if ($prop.Name -eq 'five_hour') { $main = $pct }
    }
    if (-not $lines) { $lines += New-Line 'No data' $null 'the service returned no limits' }
    [pscustomobject]@{ Lines = $lines; Main = $main }
}

function Convert-StatuslineLimits($rl) {
    $fake = [ordered]@{}
    foreach ($prop in $rl.PSObject.Properties) {
        $v = $prop.Value
        if ($null -eq $v -or $null -eq $v.PSObject.Properties['used_percentage']) { continue }
        $fake[$prop.Name] = [pscustomobject]@{ utilization = $v.used_percentage; resets_at = $v.resets_at }
    }
    Convert-ClaudeUsage ([pscustomobject]$fake)
}

# Official status pages; one request per page per refresh.
$script:statusCache = @{}
function Get-ServiceStatus([string]$type) {
    $page = switch ($type) {
        { $_ -in 'claude-code', 'claude-web', 'anthropic-api' } { 'anthropic' }
        { $_ -in 'codex', 'openai-api' } { 'openai' }
        'deepseek' { 'deepseek' }
        default { $null }
    }
    if (-not $page) { return $null }
    if ($script:statusCache.ContainsKey($page)) { return $script:statusCache[$page] }
    $res = $null
    $urls = @{ anthropic = 'https://status.claude.com/api/v2/status.json'; openai = 'https://status.openai.com/api/v2/status.json'; deepseek = 'https://status.deepseek.com/api/v2/status.json' }
    try {
        $j = Invoke-RestMethod -Uri $urls[$page] -TimeoutSec 8 -UseBasicParsing
        $ind = [string]$j.status.indicator
        if ($ind -and $ind -ne 'none') { $res = [pscustomobject]@{ Text = [string]$j.status.description; Level = $ind } }
    } catch {
        if ($page -eq 'openai') {
            try {
                $j = Invoke-RestMethod -Uri 'https://status.openai.com/proxy/status.openai.com' -TimeoutSec 8 -UseBasicParsing
                $inc = @($j.summary.ongoing_incidents)
                if ($inc.Count -gt 0 -and $inc[0]) { $res = [pscustomobject]@{ Text = [string]$inc[0].name; Level = 'minor' } }
            } catch {}
        }
    }
    $script:statusCache[$page] = $res
    $res
}

function Get-ClaudeWebUsage([string]$sk) {
    $h = @{ Cookie = "sessionKey=$sk" }
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'
    $orgs = @(Invoke-Json 'https://claude.ai/api/organizations' $h $ua)
    $org = $orgs | Where-Object { @($_.capabilities) -contains 'chat' } | Select-Object -First 1
    if (-not $org) { $org = $orgs[0] }
    Invoke-Json ("https://claude.ai/api/organizations/{0}/usage" -f $org.uuid) $h $ua
}

function Get-BridgeNote([int64]$now, [string]$claudeDir, [string]$suffix) {
    $sf = Join-Path $claudeDir 'settings.json'
    $on = $false
    try { if (Test-Path $sf) { $on = ((Get-Content $sf -Raw -Encoding UTF8) -match 'AILimits/statusline\.ps1') } } catch {}
    if (-not $on) { return $null }
    $pf = Join-Path $env:APPDATA ('AILimits\claude-bridge-ping' + $suffix + '.json')
    if (-not (Test-Path $pf)) { return 'Claude Code has not called it yet — restart Claude Code in the terminal and send a message' }
    try { $pg = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    $when = [DateTimeOffset]::FromUnixTimeSeconds([int64]$pg.at).ToLocalTime().ToString('dd.MM HH:mm')
    if (-not $pg.has_rate_limits) { return ('Claude Code calls it (' + $when + ') but without limits — send a message in Claude Code') }
    'last data from Claude Code: ' + $when
}

function Get-ClaudeDir($p) {
    if ($p.configDir) { return [Environment]::ExpandEnvironmentVariables([string]$p.configDir) }
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    Join-Path $env:USERPROFILE '.claude'
}

# Accounts other than the default one get their own bridge file name (same rule as in the bridge script).
function Get-AcctSuffix($p) {
    if (-not $p.configDir) { return '' }
    $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$p.configDir)).TrimEnd('\').ToLowerInvariant()
    $md5 = [Security.Cryptography.MD5]::Create()
    $hex = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($full)) | ForEach-Object { $_.ToString('x2') })
    '-' + $hex.Substring(0, 8)
}

function Get-ProfileName($p) { if ($p.profile) { return [string]$p.profile }; 'browser' }

function Test-OnBattery {
    try { return ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline) } catch { return $false }
}

function Save-ClaudeCache($path, $okAt, $backoff, $boMin, $data, $nextAt, $gap) {
    Save-JsonFile $path ([ordered]@{ okAt = $okAt; backoffUntil = $backoff; backoffMin = $boMin; nextAt = $nextAt; gap = $gap; data = $data })
}

# Limit history for the charts: one line per reading, kept for 30 days.
function Add-History([string]$id, [int64]$at, $lines) {
    try {
        $f = Join-Path $env:APPDATA ('AILimits\history-' + $id + '.tsv')
        if (Test-Path $f) {
            $last = Get-Content $f -Tail 1 -ErrorAction SilentlyContinue
            if ($last -and ([int64]($last.Split("`t")[0])) -ge $at) { return }
            if ((Get-Item $f).Length -gt 2MB) {
                $cut = $at - 30 * 86400
                $keep = @(Get-Content $f | Where-Object { [int64]($_.Split("`t")[0]) -ge $cut })
                Set-Content -Path $f -Value $keep -Encoding UTF8
            }
        }
        $out = @()
        foreach ($ln in @($lines)) {
            if ($null -eq $ln.Pct) { continue }
            $out += ("{0}`t{1}`t{2}" -f $at, $ln.Label, ([double]$ln.Pct).ToString([Globalization.CultureInfo]::InvariantCulture))
        }
        if ($out) { Add-Content -Path $f -Value $out -Encoding UTF8 }
    } catch {}
}

function Get-PlanPrice($p, [string]$tool, $cred, [string]$planType) {
    $v = 0.0
    if ($p.planPrice) { try { $v = To-Num (([string]$p.planPrice) -replace ',', '.') } catch { $v = 0.0 } }
    if ($v -gt 0) { return $v }
    if ($tool -eq 'claude' -and $cred) {
        $sub = [string]$cred.claudeAiOauth.subscriptionType; $tier = [string]$cred.claudeAiOauth.rateLimitTier
        if ($tier -match '20x') { return 200.0 }
        if ($sub -eq 'max' -or $tier -match '5x') { return 100.0 }
        if ($sub -eq 'pro') { return 20.0 }
    }
    if ($tool -eq 'codex') {
        switch -regex ($planType) { '^pro' { return 200.0 } '^plus' { return 20.0 } '^(team|business)' { return 30.0 } }
    }
    0.0
}

# Reads new lines from the account's logs and turns them into "API value" lines for the card.
function Get-UsageLines($p, [string]$tool, [string]$homeDir, [double]$plan) {
    try {
        $stDir = Join-Path $env:APPDATA 'AILimits'
        $uDir = Join-Path $stDir 'usage'
        if ($tool -eq 'claude') { [void][AILimitsUI.UsageLog]::Scan($p.id, $uDir, (Join-Path $homeDir 'projects'), '') }
        else { [void][AILimitsUI.UsageLog]::Scan($p.id, $uDir, '', $homeDir) }
        $sum = [AILimitsUI.UsageLog]::Summarize($p.id, $uDir, (Join-Path $stDir 'pricing.tsv'), [DateTime]::Now)
        if ($sum.MonthRequests -le 0) { return }
        New-Line 'API value, month' $null ('${0:N0}' -f $sum.MonthCost)
        New-Line 'Today' $null ('${0:N2}' -f $sum.TodayCost)
        if ($plan -gt 0) { New-Line ('vs ${0:N0} plan' -f $plan) $null ('×{0:N1}' -f ($sum.MonthCost / $plan)) }
    } catch {}
}

function Save-JsonFile($path, $obj) {
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $path -Force
}

function Get-MonthStartUtc {
    $n = [DateTime]::UtcNow
    New-Object DateTime($n.Year, $n.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
}

function Get-BudgetLines([double]$spent, $budget) {
    $b = 0.0
    if ($budget) { try { $b = To-Num (([string]$budget) -replace ',', '.') } catch { $b = 0.0 } }
    if ($b -gt 0) {
        $pct = [math]::Min(100, $spent / $b * 100)
        New-Line 'Budget left' $pct ('${0:N2} of ${1:N2}' -f ($b - $spent), $b) ($spent -ge $b)
    }
    New-Line 'Spent this month' $null ('${0:N2}' -f $spent)
}

foreach ($p in $providers) {
    $lines = @(); $main = $null; $err = $null; $newWebKey = $null; $askRefresh = $false
    try {
        $key = [string]$p.plainKey
        switch ($p.type) {
            'claude-code' {
                $stDir = Join-Path $env:APPDATA 'AILimits'
                $claudeDir = Get-ClaudeDir $p
                $suffix = Get-AcctSuffix $p
                $profileDir = Join-Path $stDir (Get-ProfileName $p)
                if ((Get-ProfileName $p) -eq 'browser') { $cacheF = Join-Path $stDir 'claude-cache.json' } else { $cacheF = Join-Path $stDir ('claude-cache-' + $p.id + '.json') }
                $slF = Join-Path $stDir ('claude-statusline' + $suffix + '.json')
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $force = [bool]$p.force
                $cache = $null
                if (Test-Path $cacheF) { try { $cache = Get-Content $cacheF -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cache = $null } }
                $sl = $null; $slAt = 0
                if (Test-Path $slF) { try { $sl = Get-Content $slF -Raw -Encoding UTF8 | ConvertFrom-Json; $slAt = [int64]$sl.saved_at } catch { $sl = $null } }
                $okAt = 0; $backoff = 0; $boMin = 0; $cdata = $null; $nextAt = 0; $gap = 0
                if ($cache) {
                    if ($cache.okAt) { $okAt = [int64]$cache.okAt }
                    if ($cache.backoffUntil) { $backoff = [int64]$cache.backoffUntil }
                    if ($cache.backoffMin) { $boMin = [int]$cache.backoffMin }
                    if ($cache.nextAt) { $nextAt = [int64]$cache.nextAt }
                    if ($cache.gap) { $gap = [int]$cache.gap }
                    $cdata = $cache.data
                }
                $src = $null; $note = $null; $r = $null; $webNote = $null
                $c = $null; $credF = Join-Path $claudeDir '.credentials.json'
                if (Test-Path $credF) { try { $c = Get-Content $credF -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $c = $null } }

                # 1) bridge from the terminal Claude Code: free and exact
                if ($sl -and $sl.rate_limits -and ($now - $slAt) -lt 900 -and $slAt -ge $okAt) { $src = 'sl' }
                elseif (-not $force -and $cdata -and ($now - $okAt) -lt 120) { $src = 'cache' }

                # 2) claude.ai through the background browser, polled adaptively
                $webKey = [string]$p.plainWebKey
                if (-not $src -and (Test-Path $profileDir) -and (Find-Browser)) {
                    if ($force -or $now -ge $nextAt) {
                        try {
                            $r = Get-ClaudeUsageViaBrowser $profileDir
                            $src = 'api'
                            $changed = $true
                            if ($cdata) {
                                $d5 = [math]::Abs([double]$r.five_hour.utilization - [double]$cdata.five_hour.utilization)
                                $d7 = [math]::Abs([double]$r.seven_day.utilization - [double]$cdata.seven_day.utilization)
                                $changed = ($d5 -ge 0.5 -or $d7 -ge 0.5)
                            }
                            if ($changed) { $gap = 180 } elseif ($gap -lt 300) { $gap = 300 } else { $gap = [math]::Min(1800, $gap * 2) }
                            $wait = $gap
                            if (Test-OnBattery) { $wait = $gap * 2 }
                            $nextAt = $now + $wait
                            Save-ClaudeCache $cacheF $now $backoff $boMin $r $nextAt $gap
                        } catch {
                            if ($_.Exception.Message -eq 'NOT_SIGNED_IN') { $webNote = 'sign in to claude.ai once: Settings → this account → "Sign in to claude.ai…"' }
                            else { $webNote = 'claude.ai: ' + $_.Exception.Message }
                            $nextAt = $now + 900
                            Save-ClaudeCache $cacheF $okAt $backoff $boMin $cdata $nextAt $gap
                        }
                    } elseif ($cdata) {
                        $src = 'cache'   # quiet period: the last reading is still the best one
                    }
                } elseif (-not $src -and $webKey) {
                    try {
                        $r = Get-ClaudeWebUsage $webKey
                        $src = 'api'
                        Save-ClaudeCache $cacheF $now $backoff $boMin $r $nextAt $gap
                    } catch {
                        if (Test-CfBlock $_) { $webNote = 'claude.ai blocks direct requests — sign in once: Settings → this account → "Sign in to claude.ai…"' }
                        elseif ((Get-Code $_) -in 401, 403) { $webNote = 'claude.ai rejected the session key — Settings → this account → "Sign in to claude.ai…"' }
                        else { $webNote = 'claude.ai: ' + $_.Exception.Message }
                    }
                }

                # 3) the Claude Code sign-in (rate-limited endpoint)
                if ($src) { }
                elseif ($cdata -and ($now - $okAt) -lt 540) { $src = 'cache' }
                elseif ($backoff -gt $now) {
                    $note = 'Anthropic asked to wait, retrying at ' + [DateTimeOffset]::FromUnixTimeSeconds($backoff).ToLocalTime().ToString('HH:mm')
                } else {
                    $token = $key
                    if (-not $token -and $c) {
                        $token = $c.claudeAiOauth.accessToken
                        $exp = $c.claudeAiOauth.expiresAt
                        if ($exp -and ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$exp) -lt [DateTimeOffset]::UtcNow.AddMinutes(1))) {
                            $token = $null
                            if ($p.autoRefresh -eq $true) {
                                if (Test-ClaudeCodeRunning) {
                                    $note = 'Claude Code is running — it will renew its own sign-in'
                                } else {
                                    try { $token = Update-ClaudeCodeToken $credF } catch { $token = $null }
                                    if (-not $token) { $note = 'could not renew the Claude Code sign-in — run claude once' }
                                }
                            } elseif ($null -eq $p.autoRefresh) {
                                $askRefresh = $true
                                $note = 'the Claude Code sign-in expired'
                            } else {
                                $note = 'the Claude Code sign-in expired — run claude, or allow auto-renew in Settings'
                            }
                        }
                    } elseif (-not $token -and -not (Test-Path $profileDir)) {
                        $note = 'no Claude sign-in found — Settings → "Connect automatically…"'
                    }
                    if ($token) {
                        try {
                            $r = Invoke-Json 'https://api.anthropic.com/api/oauth/usage' @{ Authorization = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' } 'claude-code/2.1.0'
                            $src = 'api'
                            Save-ClaudeCache $cacheF $now 0 0 $r $nextAt $gap
                        } catch {
                            $code = Get-Code $_
                            if ($code -eq 401) { $note = 'the token was rejected — run claude to refresh the sign-in' }
                            elseif ($code -eq 429) {
                                if ($boMin -lt 15) { $boMin = 15 } else { $boMin = [math]::Min(60, $boMin * 2) }
                                $backoff = $now + $boMin * 60
                                Save-ClaudeCache $cacheF $okAt $backoff $boMin $cdata $nextAt $gap
                                $note = 'Anthropic said "too many requests" (429), retrying at ' + [DateTimeOffset]::FromUnixTimeSeconds($backoff).ToLocalTime().ToString('HH:mm')
                            } else { throw }
                        }
                    }
                }
                if ($webNote) { if ($note) { $note = $webNote + '; ' + $note } else { $note = $webNote } }
                if (-not $src) {
                    if ($sl -and $sl.rate_limits -and $slAt -ge $okAt) { $src = 'sl' }
                    elseif ($cdata) { $src = 'cache' }
                }
                if ($src -eq 'sl') { $u = Convert-StatuslineLimits $sl.rate_limits; $dataAt = $slAt }
                elseif ($src -eq 'cache') { $u = Convert-ClaudeUsage $cdata; $dataAt = $okAt }
                elseif ($src -eq 'api') { $u = Convert-ClaudeUsage $r; $dataAt = $now }
                else {
                    $bn = Get-BridgeNote $now $claudeDir $suffix
                    if ($bn) { throw ('No data yet: ' + $note + '. Bridge: ' + $bn + '.') }
                    throw ('No data yet: ' + $note + '.')
                }
                $lines = @($u.Lines); $main = $u.Main
                if ($src -in 'api', 'sl') { Add-History $p.id $dataAt $lines }

                # API value of this account's Claude Code use, from its local logs
                $plan = Get-PlanPrice $p 'claude' $c $null
                $lines += @(Get-UsageLines $p 'claude' $claudeDir $plan)

                if ($src -ne 'sl') { $bn = Get-BridgeNote $now $claudeDir $suffix; if ($bn) { $lines += New-Line 'Bridge' $null $bn } }
                if ($src -eq 'sl') { $lines += New-Line 'Data' $null ('from Claude Code · ' + (Format-Ago ($now - $dataAt))) }
                elseif (($now - $dataAt) -gt 120) { $lines += New-Line 'Data' $null (Format-Ago ($now - $dataAt)) }
                if ($note) { $lines += New-Line 'Note' $null $note $true }
            }
            'claude-web' {
                if (-not $key) { throw 'Paste the session key in Settings.' }
                try {
                    $r = Get-ClaudeWebUsage $key
                } catch {
                    $code = Get-Code $_
                    if ($code -eq 401 -or $code -eq 403) { throw "Error $code — the session key expired or claude.ai blocked the request. Get a fresh session key." }
                    throw
                }
                $u = Convert-ClaudeUsage $r; $lines = $u.Lines; $main = $u.Main
            }
            'codex' {
                if ($p.configDir) { $dir = [Environment]::ExpandEnvironmentVariables([string]$p.configDir) }
                elseif ($env:CODEX_HOME) { $dir = $env:CODEX_HOME } else { $dir = Join-Path $env:USERPROFILE '.codex' }
                $f = Join-Path $dir 'auth.json'
                if (-not (Test-Path $f)) { throw 'Not signed in to Codex. Open Settings → "Connect automatically…".' }
                $a = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
                $tok = $a.tokens.access_token
                if (-not $tok) { throw 'Codex is signed in with an API key, not a ChatGPT account, so there are no plan limits. Run codex login and choose Sign in with ChatGPT.' }
                $h = @{ Authorization = "Bearer $tok" }
                if ($a.tokens.account_id) { $h['ChatGPT-Account-Id'] = [string]$a.tokens.account_id }
                try {
                    $r = Invoke-Json 'https://chatgpt.com/backend-api/wham/usage' $h 'codex-cli'
                } catch {
                    if ((Get-Code $_) -eq 401) { throw 'The Codex sign-in expired — run codex in a terminal to refresh it.' }
                    throw
                }
                $rl = $r.rate_limit
                foreach ($wn in @('primary_window', 'secondary_window')) {
                    $w = $null
                    if ($rl) { $w = $rl.$wn }
                    if ($null -eq $w -or $null -eq $w.used_percent) { continue }
                    $secs = 0
                    if ($w.limit_window_seconds) { $secs = [int64]$w.limit_window_seconds }
                    if ($secs -eq 18000) { $label = '5-hour limit' }
                    elseif ($secs -eq 604800) { $label = 'Weekly' }
                    elseif ($secs -ge 2419200) { $label = 'Monthly' }
                    elseif ($secs -ge 86400) { $label = ('{0}-day limit' -f [math]::Round($secs / 86400)) }
                    elseif ($secs -gt 0) { $label = ('{0}-hour limit' -f [math]::Round($secs / 3600)) }
                    else { $label = $wn }
                    $pct = [double]$w.used_percent
                    $resetSrc = $w.reset_at
                    if (-not $resetSrc -and $w.reset_after_seconds) { $resetSrc = [DateTimeOffset]::UtcNow.AddSeconds([double]$w.reset_after_seconds).ToUnixTimeSeconds() }
                    $text = '{0}%' -f [math]::Round($pct)
                    $rs = Format-Reset $resetSrc
                    if ($rs) { $text += ' · resets in ' + $rs } else { $rs = $null }
                    $lines += New-Line $label $pct $text $false $rs
                    if ($null -eq $main) { $main = $pct }
                }
                if (-not $lines) { $lines += New-Line 'No data' $null 'the service returned no limits' }
                else { Add-History $p.id ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) $lines }
                if ($r.plan_type) { $lines += New-Line 'Plan' $null ([string]$r.plan_type) }
                $plan = Get-PlanPrice $p 'codex' $null ([string]$r.plan_type)
                $lines += @(Get-UsageLines $p 'codex' $dir $plan)
            }
            'gemini' {
                $f = Join-Path $env:USERPROFILE '.gemini\oauth_creds.json'
                if (-not (Test-Path $f)) { throw 'Not signed in to Gemini CLI. Open Settings → "Connect automatically…".' }
                $cr = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
                $tok = $cr.access_token
                $expired = $true
                if ($cr.expiry_date) { $expired = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$cr.expiry_date) -lt [DateTimeOffset]::UtcNow.AddMinutes(1)) }
                if ($expired) {
                    $gc = Get-GeminiClient
                    if (-not $cr.refresh_token -or -not $gc) { throw 'The Gemini sign-in expired — run gemini in a terminal to refresh it.' }
                    $tr = Invoke-RestMethod -Uri 'https://oauth2.googleapis.com/token' -Method Post -TimeoutSec 20 -UseBasicParsing -Body @{
                        client_id = $gc.id; client_secret = $gc.secret; refresh_token = $cr.refresh_token; grant_type = 'refresh_token'
                    }
                    $tok = $tr.access_token
                }
                $h = @{ Authorization = "Bearer $tok" }
                $proj = $env:GOOGLE_CLOUD_PROJECT
                if (-not $proj) {
                    $lc = Invoke-JsonPost 'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist' $h @{ metadata = @{ ideType = 'IDE_UNSPECIFIED'; platform = 'PLATFORM_UNSPECIFIED'; pluginType = 'GEMINI' } }
                    $cp = $lc.cloudaicompanionProject
                    if ($cp -is [string]) { $proj = $cp } elseif ($cp) { $proj = $cp.id }
                }
                $body = @{}
                if ($proj) { $body['project'] = $proj }
                $q = Invoke-JsonPost 'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota' $h $body
                $seen = @{}
                foreach ($bk in @($q.buckets)) {
                    if ($null -eq $bk.remainingFraction -or -not $bk.modelId) { continue }
                    if ($seen.ContainsKey([string]$bk.modelId)) { continue }
                    $seen[[string]$bk.modelId] = 1
                    $pct = [math]::Max(0, [math]::Min(100, (1 - [double]$bk.remainingFraction) * 100))
                    $text = '{0}%' -f [math]::Round($pct)
                    $rs = Format-Reset $bk.resetTime
                    if ($rs) { $text += ' · resets in ' + $rs } else { $rs = $null }
                    $lines += New-Line ([string]$bk.modelId) $pct $text $false $rs
                    if ($lines.Count -ge 4) { break }
                }
                if (-not $lines) { $lines += New-Line 'No data' $null 'the service returned no quotas' }
            }
            'anthropic-api' {
                if (-not $key) { throw 'Paste an Admin key in Settings.' }
                $sa = (Get-MonthStartUtc).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv)
                $sum = 0.0; $page = $null
                for ($i = 0; $i -lt 6; $i++) {
                    $url = 'https://api.anthropic.com/v1/organizations/cost_report?limit=31&starting_at=' + [uri]::EscapeDataString($sa)
                    if ($page) { $url += '&page=' + [uri]::EscapeDataString($page) }
                    $r = Invoke-Json $url @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' }
                    foreach ($b in @($r.data)) { foreach ($row in @($b.results)) { if ($null -ne $row.amount) { $sum += To-Num $row.amount } } }
                    if (-not $r.has_more) { break }
                    $page = $r.next_page
                }
                if ($p.cents) { $sum = $sum / 100 }
                $lines = @(Get-BudgetLines $sum $p.budget)
            }
            'openai-api' {
                if (-not $key) { throw 'Paste an Admin key in Settings.' }
                $st = ([DateTimeOffset]::new((Get-MonthStartUtc))).ToUnixTimeSeconds()
                $sum = 0.0; $page = $null
                for ($i = 0; $i -lt 6; $i++) {
                    $url = "https://api.openai.com/v1/organization/costs?start_time=$st&limit=31"
                    if ($page) { $url += '&page=' + [uri]::EscapeDataString($page) }
                    $r = Invoke-Json $url @{ Authorization = "Bearer $key" }
                    foreach ($b in @($r.data)) { foreach ($row in @($b.results)) { if ($null -ne $row.amount) { $sum += To-Num $row.amount.value } } }
                    if (-not $r.has_more) { break }
                    $page = $r.next_page
                }
                $lines = @(Get-BudgetLines $sum $p.budget)
            }
            'openrouter' {
                if (-not $key) { throw 'Paste an API key in Settings.' }
                $hdr = @{ Authorization = "Bearer $key" }
                $done = $false
                try {
                    $r = Invoke-Json 'https://openrouter.ai/api/v1/credits' $hdr
                    $tc = To-Num $r.data.total_credits; $tu = To-Num $r.data.total_usage
                    $pct = $null; if ($tc -gt 0) { $pct = [math]::Min(100, $tu / $tc * 100) }
                    $lines += New-Line 'Balance' $pct ('${0:N2} of ${1:N2}' -f ($tc - $tu), $tc) (($tc - $tu) -le 0)
                    $done = $true
                } catch {
                    $code = Get-Code $_
                    if ($code -ne 401 -and $code -ne 403) { throw }
                }
                if (-not $done) {
                    $k = Invoke-Json 'https://openrouter.ai/api/v1/key' $hdr
                    $d = $k.data
                    if ($null -ne $d.limit) {
                        $lim = To-Num $d.limit; $rem = To-Num $d.limit_remaining
                        $pct = $null; if ($lim -gt 0) { $pct = [math]::Min(100, ($lim - $rem) / $lim * 100) }
                        $lines += New-Line 'Key limit' $pct ('${0:N2} of ${1:N2}' -f $rem, $lim) ($rem -le 0)
                    }
                    $lines += New-Line 'Key spend' $null ('${0:N2} total' -f (To-Num $d.usage))
                }
            }
            'deepseek' {
                if (-not $key) { throw 'Paste an API key in Settings.' }
                $r = Invoke-Json 'https://api.deepseek.com/user/balance' @{ Authorization = "Bearer $key" }
                foreach ($bi in @($r.balance_infos)) {
                    if ($bi.currency -eq 'CNY') { $sym = '¥' } else { $sym = '$' }
                    $lines += New-Line ('Balance ' + $bi.currency) $null ('{0}{1:N2}' -f $sym, (To-Num $bi.total_balance)) (-not $r.is_available)
                }
                if (-not $lines) { $lines += New-Line 'Balance' $null 'no data' }
            }
            'custom' {
                if (-not $p.url) { throw 'Set the URL in Settings.' }
                if (-not $p.valuePath) { throw 'Set the remaining value path in Settings.' }
                $h = @{}
                if ($p.header -and ([string]$p.header) -match '^\s*([^:]+):\s*(.*)$') {
                    $h[$matches[1].Trim()] = $matches[2].Replace('{key}', $key)
                }
                $r = Invoke-Json $p.url $h
                $raw = Get-JsonPath $r $p.valuePath
                if ($null -eq $raw) { throw ('No value in the response at path ' + $p.valuePath) }
                $val = To-Num $raw
                $unit = [string]$p.unit
                if ($p.totalPath) {
                    $tot = To-Num (Get-JsonPath $r $p.totalPath)
                    $pct = $null; if ($tot -gt 0) { $pct = [math]::Max(0, [math]::Min(100, ($tot - $val) / $tot * 100)) }
                    $lines += New-Line 'Remaining' $pct ('{0}{1:N2} of {0}{2:N2}' -f $unit, $val, $tot) ($val -le 0)
                } else {
                    $lines += New-Line 'Remaining' $null ('{0}{1:N2}' -f $unit, $val) ($val -le 0)
                }
            }
            default { throw ('Unknown type ' + $p.type) }
        }
    } catch {
        $err = Get-ErrText $_
    }
    $stText = $null; $stLevel = $null
    try { $sv = Get-ServiceStatus ([string]$p.type); if ($sv) { $stText = $sv.Text; $stLevel = $sv.Level } } catch {}
    [pscustomobject]@{ Id = $p.id; Name = $p.name; Type = $p.type; Lines = @($lines); Error = $err; Main = $main; NewWebKey = $newWebKey; AskRefresh = $askRefresh; Status = $stText; StatusLevel = $stLevel }
}
'@

# ---------- Claude Code status line bridge ----------
$BridgePath = Join-Path $AppDir 'statusline.ps1'
$BridgeCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + ($BridgePath -replace '\\', '/') + '"'
$BridgeScript = @'
# AI Limits bridge: Claude Code passes its status JSON here; we save rate_limits for the widget.
$ErrorActionPreference = 'SilentlyContinue'
$raw = [Console]::In.ReadToEnd()
$dir = Join-Path $env:APPDATA 'AILimits'
$sfx = ''
if ($env:CLAUDE_CONFIG_DIR) {
    $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:CLAUDE_CONFIG_DIR)).TrimEnd('\').ToLowerInvariant()
    $def = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude')).TrimEnd('\').ToLowerInvariant()
    if ($full -ne $def) {
        $md5 = [Security.Cryptography.MD5]::Create()
        $sfx = '-' + (-join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($full)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
    }
}
$out = ''
try {
    $j = $raw | ConvertFrom-Json
    $ping = [ordered]@{ at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); has_rate_limits = [bool]$j.rate_limits; keys = (@($j.PSObject.Properties.Name) -join ',') }
    [IO.File]::WriteAllText((Join-Path $dir ('claude-bridge-ping' + $sfx + '.json')), ($ping | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    if ($j.rate_limits) {
        $o = [ordered]@{ saved_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); rate_limits = $j.rate_limits }
        $dst = Join-Path $dir ('claude-statusline' + $sfx + '.json')
        [IO.File]::WriteAllText($dst + '.tmp', ($o | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        Move-Item -Path ($dst + '.tmp') -Destination $dst -Force
    }
    $parts = @()
    if ($j.model.display_name) { $parts += [string]$j.model.display_name }
    if ($j.rate_limits.five_hour) { $parts += ('5h {0}%' -f [math]::Round([double]$j.rate_limits.five_hour.used_percentage)) }
    if ($j.rate_limits.seven_day) { $parts += ('7d {0}%' -f [math]::Round([double]$j.rate_limits.seven_day.used_percentage)) }
    $out = $parts -join ' | '
} catch {}
$prevF = Join-Path $dir 'statusline-prev.txt'
if (Test-Path $prevF) {
    $prev = (Get-Content $prevF -Raw).Trim()
    if ($prev) {
        $res = $raw | cmd.exe /c $prev 2>$null
        if ($res) { $out = ($res -join "`n") }
    }
}
[Console]::Out.Write($out)
'@
try { [IO.File]::WriteAllText($BridgePath, $BridgeScript, (New-Object Text.UTF8Encoding($false))) } catch { Write-Log "bridge: $_" }

function Get-ClaudeSettingsPath {
    if ($env:CLAUDE_CONFIG_DIR) { return (Join-Path $env:CLAUDE_CONFIG_DIR 'settings.json') }
    Join-Path $env:USERPROFILE '.claude\settings.json'
}

function Test-Bridge {
    $f = Get-ClaudeSettingsPath
    if (-not (Test-Path $f)) { return $false }
    try { return ((Get-Content $f -Raw -Encoding UTF8) -match 'AILimits/statusline\.ps1') } catch { return $false }
}

# ---------- widget ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:cfg = Load-Config
Install-Launcher

$PricingPath = Join-Path $AppDir 'pricing.tsv'
$PricingVersion = '# v1 2026-11'
if (-not (Test-Path $PricingPath) -or ((Get-Content $PricingPath -TotalCount 1) -ne $PricingVersion)) {
@"
$PricingVersion
# Prices in USD per 1M tokens: model pattern (regex), input, output, cache read, cache write 5m, cache write 1h.
# The first matching line wins. Edit freely; delete the first line to stop updates from overwriting your edits.
fable|mythos	8	40	0.2	10	16
opus-5-5|opus-5\.5	4	20	0.2	5	8
opus-5	5	25	0.5	6.25	10
opus-4-[5-9]	5	25	0.5	6.25	10
opus	15	75	1.5	18.75	30
sonnet-5-5|sonnet-5\.5	2	10	0.1	2.5	4
sonnet-5	2	10	0.2	2.5	4
sonnet	3	15	0.3	3.75	6
haiku-5-5|haiku-5\.5	0.1	0.5	0.01	0.125	0.2
haiku-4-5	1	5	0.1	1.25	2
haiku	0.8	4	0.08	1	1.6
gpt-5\.5-pro	30	180	30	30	30
gpt-5\.5	5	30	0.5	5	5
gpt-5\.6	8	40	0.8	10	10
gpt-5\.4-mini	0.75	4.5	0.075	0.75	0.75
gpt-5\.4	2.5	15	0.25	2.5	2.5
codex	1.75	14	0.175	1.75	1.75
gpt-5	1.25	10	0.125	1.25	1.25
claude-default	2	10	0.1	2.5	4
openai-default	5	30	0.5	5	5
"@ | Set-Content -Path $PricingPath -Encoding UTF8
}
if (-not $script:cfg.Contains('theme')) { $script:cfg['theme'] = 'dark' }
$script:job = $null
$script:pendingRefresh = $false
$script:exiting = $false
$script:hIcon = [IntPtr]::Zero
$script:firstPlace = ($script:cfg.x -lt 0)
$script:results = $null
$script:statusText = 'Loading…'
$script:btns = @()
$script:hover = $null
$script:pressed = $null
$script:inCheck = $false

$WidgetW = S 300
$Gap = S 8

$form = New-Object AILimitsUI.LayeredForm
$form.Text = $AppName
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Size = New-Object System.Drawing.Size($WidgetW, (S 140))
$form.MaximizeBox = $false
$script:lastDown = 0
$script:suppressed = $false

$tooltip = New-Object System.Windows.Forms.ToolTip
$TextFlags = [System.Windows.Forms.TextFormatFlags]'NoPadding, NoPrefix, SingleLine'
$WrapFlags = [System.Windows.Forms.TextFormatFlags]'NoPadding, NoPrefix, WordBreak'
$script:maskG = $null

function Get-Theme { $Glass }

# meter colour: ink while fine, orange from 80%, red from 95%
function Get-LevelColor([double]$pct) {
    $t = Get-Theme
    if ($pct -ge 95) { return $t.Bad }
    if ($pct -ge 80) { return $t.Warn }
    $t.Ink
}
function Get-LevelText([double]$pct) {
    $t = Get-Theme
    if ($pct -ge 95) { return $t.BadFg }
    if ($pct -ge 80) { return $t.WarnFg }
    $t.Primary
}

# Text modes: 'crisp' = grayscale anti-aliasing snapped to the pixel grid (default),
# 'smooth' = grayscale without snapping, 'cleartype' = GDI ClearType.
$script:measureBmp = New-Object System.Drawing.Bitmap(1, 1)
$script:measureG = [System.Drawing.Graphics]::FromImage($script:measureBmp)
$TypoFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
$TypoFormat.FormatFlags = $TypoFormat.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces

function Get-TextMode { $m = [string]$script:cfg.textMode; if ($m -in 'crisp', 'smooth', 'cleartype') { return $m }; 'crisp' }
function Get-TextHint {
    switch (Get-TextMode) {
        'smooth' { return [System.Drawing.Text.TextRenderingHint]::AntiAlias }
        'cleartype' { return [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit }
        default { return [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit }
    }
}

function Measure-Str([string]$s, $font) {
    if ((Get-TextMode) -eq 'cleartype') {
        return [System.Windows.Forms.TextRenderer]::MeasureText($s, $font, [System.Drawing.Size]::new([int]::MaxValue, [int]::MaxValue), $TextFlags)
    }
    $script:measureG.TextRenderingHint = Get-TextHint
    $sz = $script:measureG.MeasureString($s, $font, [System.Drawing.PointF]::new(0, 0), $TypoFormat)
    [System.Drawing.Size]::new([int][math]::Ceiling($sz.Width), [int][math]::Ceiling($font.GetHeight()))
}

function Draw-Str($g, [bool]$draw, [string]$s, $font, $color, [single]$x, [single]$y, [string]$align = 'left') {
    $sz = Measure-Str $s $font
    if ($align -eq 'right') { $x = $x - $sz.Width }
    if ($draw) {
        $px = [int][math]::Round($x); $py = [int][math]::Round($y)
        if ((Get-TextMode) -eq 'cleartype') {
            [System.Windows.Forms.TextRenderer]::DrawText($g, $s, $font, [System.Drawing.Point]::new($px, $py), $color, $TextFlags)
        } else {
            $g.TextRenderingHint = Get-TextHint
            $br = New-Object System.Drawing.SolidBrush($color)
            $g.DrawString($s, $font, $br, [single]$px, [single]$py, $TypoFormat)
            $br.Dispose()
        }
    }
    $sz
}

function Draw-Wrapped($g, [bool]$draw, [string]$s, $font, $color, [single]$x, [single]$y, [single]$w) {
    if ((Get-TextMode) -eq 'cleartype') {
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($s, $font, [System.Drawing.Size]::new([int]$w, [int]::MaxValue), $WrapFlags)
        if ($draw) {
            $rect = [System.Drawing.Rectangle]::new([int][math]::Round($x), [int][math]::Round($y), [int]$w, $sz.Height + 2)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $s, $font, $rect, $color, $WrapFlags)
        }
        return $sz.Height
    }
    $script:measureG.TextRenderingHint = Get-TextHint
    $sf = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericTypographic)
    $szf = $script:measureG.MeasureString($s, $font, [int]$w, $sf)
    $hgt = [int][math]::Ceiling($szf.Height)
    if ($draw) {
        $g.TextRenderingHint = Get-TextHint
        $br = New-Object System.Drawing.SolidBrush($color)
        $g.DrawString($s, $font, $br, (New-Object System.Drawing.RectangleF([single][math]::Round($x), [single][math]::Round($y), $w, ($hgt + 2))), $sf)
        $br.Dispose()
    }
    $sf.Dispose()
    $hgt
}

function Fill-Round($g, $color, [single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $path = New-RoundPath $x $y $w $h $r
    $br = New-Object System.Drawing.SolidBrush($color)
    $g.FillPath($br, $path)
    $br.Dispose(); $path.Dispose()
}

function Fill-Rect($g, $color, [single]$x, [single]$y, [single]$w, [single]$h) {
    if ($w -le 0 -or $h -le 0) { return }
    $br = New-Object System.Drawing.SolidBrush($color)
    $g.FillRectangle($br, $x, $y, $w, $h)
    $br.Dispose()
}

# 1px hairline, snapped to the pixel grid so it stays sharp
function Draw-Rule($g, $color, [single]$x1, [single]$x2, [single]$y, [switch]$Dashed) {
    $yy = [math]::Round($y) + 0.5
    $pen = New-Object System.Drawing.Pen($color, 1)
    if ($Dashed) { $pen.DashPattern = [single[]]@(3, 3) }
    $old = $g.SmoothingMode
    $g.SmoothingMode = 'None'
    $g.DrawLine($pen, [single]$x1, [single]$yy, [single]$x2, [single]$yy)
    $g.SmoothingMode = $old
    $pen.Dispose()
}

# distance from the top of a drawn line to its baseline (GenericTypographic draws from the cell top)
function Get-Ascent($font) {
    $ff = $font.FontFamily
    [single]($font.Size * $ff.GetCellAscent($font.Style) / $ff.GetEmHeight($font.Style))
}

# letter-spaced caps, e.g. the "AI LIMITS" header; $base is the baseline
function Draw-Tracked($g, [bool]$draw, [string]$s, $font, $color, [single]$x, [single]$base, [single]$track) {
    $cx = $x
    $y = $base - (Get-Ascent $font)
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq ' ') { $cx += [single]($font.Size * 0.32); continue }
        $sz = Draw-Str $g $draw ([string]$ch) $font $color $cx $y
        $cx += $sz.Width + $track
    }
    $cx - $x - $track
}

# cap height (used to centre text optically) and drawing by baseline
function Get-Cap($font) { [single]($font.Size * 0.70) }
function Draw-Base($g, [bool]$draw, [string]$s, $font, $color, [single]$x, [single]$base, [string]$align = 'left') {
    Draw-Str $g $draw $s $font $color $x ($base - (Get-Ascent $font)) $align
}

# shortens a string with … until it fits
function Fit-Str([string]$s, $font, [single]$maxW) {
    if ((Measure-Str $s $font).Width -le $maxW) { return $s }
    while ($s.Length -gt 1) {
        $s = $s.Substring(0, $s.Length - 1)
        if ((Measure-Str ($s.TrimEnd() + '…') $font).Width -le $maxW) { return $s.TrimEnd() + '…' }
    }
    $s
}

# The widget is one frosted panel; its silhouette goes into the alpha mask.
function Add-CardShape([single]$y, [single]$w, [single]$h, [single]$r = (S $Radius.Card)) {
    if ($script:maskG) { Fill-Round $script:maskG ([System.Drawing.Color]::White) 0 $y $w $h $r }
}

function Draw-PanelBorder($g, [single]$w, [single]$h, [single]$r) {
    $t = Get-Theme
    $p = New-RoundPath 0.5 0.5 ($w - 1) ($h - 1) $r
    $pen = New-Object System.Drawing.Pen($t.Border, 1)
    $g.DrawPath($pen, $p)
    $pen.Dispose(); $p.Dispose()
}

function Draw-IconButton($g, [bool]$draw, [string]$action, [string]$glyph, [string]$tip, [single]$x, [single]$y, [single]$size) {
    $script:btns += @{ Action = $action; Tip = $tip; Rect = (New-Object System.Drawing.RectangleF($x, $y, $size, $size)) }
    if (-not $draw) { return }
    $t = Get-Theme
    if ($script:hover -eq $action) { Fill-Round $g $t.ChipHover $x $y $size $size (S $Radius.Btn) }
    $cx = $x + $size / 2; $cy = $y + $size / 2; $is = [single](S 16)
    switch ($action) {
        'refresh' { [AILimitsUI.Icons]::LineRefresh($g, $cx, $cy, $is, $t.IconFg) }
        'settings' { [AILimitsUI.Icons]::LineSliders($g, $cx, $cy, $is, $t.IconFg) }
        'hide' { [AILimitsUI.Icons]::LineDash($g, $cx, $cy, $is, $t.IconFg) }
        'stats' { [AILimitsUI.Icons]::LineBars($g, $cx, $cy, $is, $t.IconFg) }
    }
}

function Get-MainLineIndex($lines) {
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($null -ne $lines[$i].Pct) { return $i } }
    if ($lines.Count) { return 0 }
    -1
}

function Test-NoteLine($ln) {
    ($ln.Warn -and $null -eq $ln.Pct) -or (($null -eq $ln.Pct) -and ([string]$ln.Text).Length -gt 26)
}

# "Claude · Work" -> name + muted qualifier
function Split-Name([string]$n) {
    if ($n -match '^(.+?)\s+[·\-—|]\s+(.+)$') { return @($matches[1], $matches[2]) }
    if ($n -match '^(.+?)\s+\((.+)\)$') { return @($matches[1], $matches[2]) }
    @($n, '')
}

function Get-StatusColor($r) {
    $t = Get-Theme
    if ($r.StatusLevel -in 'major', 'critical') { return @($t.Bad, $t.BadFg) }
    @($t.Warn, $t.WarnFg)
}

# Lays out (and optionally draws) one service section; returns its height.
function Layout-Card($g, [bool]$draw, $r, [single]$top, [single]$w) {
    $t = Get-Theme
    $pad = S 16
    $x0 = $pad
    $inner = $w - 2 * $pad
    $xr = $x0 + $inner

    $lines = @($r.Lines)
    $mi = -1
    if (-not $r.Error) { $mi = Get-MainLineIndex $lines }
    $main = $null
    if ($mi -ge 0) { $main = $lines[$mi] }

    # --- name row (all on one baseline): "Claude  Max" ... status on the right ---
    $nb = $top + (S 16) + (Get-Cap $Fonts.Name)
    $parts = Split-Name ([string]$r.Name)
    $nsz = Draw-Base $g $draw $parts[0] $Fonts.Name $t.Primary $x0 $nb
    $nameW = $nsz.Width
    if ($parts[1]) {
        $q = Fit-Str $parts[1] $Fonts.Plan ($inner - $nameW - (S 90))
        $qsz = Draw-Base $g $draw $q $Fonts.Plan $t.Faint ($x0 + $nameW + (S 5)) $nb
        $nameW += (S 5) + $qsz.Width
    }
    $statusBelow = $false
    if ($r.Status) {
        $sc = Get-StatusColor $r
        $stxt = [string]$r.Status
        $ssz = Measure-Str $stxt $Fonts.Small
        if ($ssz.Width + (S 12) -le $inner - $nameW - (S 12)) {
            if ($draw) { Fill-Rect $g $sc[0] ($xr - $ssz.Width - (S 12)) ($nb - (Get-Cap $Fonts.Small) / 2 - (S 3)) (S 6) (S 6) }
            [void](Draw-Base $g $draw $stxt $Fonts.Small $sc[1] $xr $nb 'right')
        } else { $statusBelow = $true }
    }
    $y = $nb + (S 4)          # bottom of the name row
    if ($statusBelow) {
        $sc = Get-StatusColor $r
        $y += S 6
        if ($draw) { Fill-Rect $g $sc[0] $x0 ($y + (S 6)) (S 6) (S 6) }
        $sh = Draw-Wrapped $g $draw ([string]$r.Status) $Fonts.Small $sc[1] ($x0 + (S 12)) $y ($inner - (S 12))
        $y += $sh
    }

    if ($r.Error) {
        $y += S 10
        $h = Draw-Wrapped $g $draw ([string]$r.Error) $Fonts.Note $t.BadFg $x0 $y $inner
        return ($y + $h + (S 14) - $top)
    }

    # --- headline: big number, unit and label on one baseline; reset time on the right ---
    if ($main) {
        $pct = $null
        if ($null -ne $main.Pct) { $pct = [math]::Max(0, [math]::Min(100, [double]$main.Pct)) }
        if ($null -ne $pct) {
            $big = [string][int][math]::Round([double]$main.Pct); $unit = '%'; $after = [string]$main.Label
        } elseif (([string]$main.Text) -match '^(.+?)\s+of\s+(.+)$') {
            $big = $matches[1]; $unit = ''; $after = 'of ' + $matches[2]
        } else {
            $big = [string]$main.Text; $unit = ''; $after = [string]$main.Label
        }
        $bigFont = $Fonts.Big
        if ((Measure-Str $big $bigFont).Width -gt $inner * 0.6) { $bigFont = $Fonts.Money }
        if ((Measure-Str $big $bigFont).Width -gt $inner * 0.7) { $bigFont = $Fonts.Value }
        if ($main.Warn) { $bc = $t.BadFg } elseif ($null -ne $pct) { $bc = Get-LevelText $pct } else { $bc = $t.Primary }
        $bb = $y + (S 14) + (Get-Cap $bigFont)          # baseline of the big number
        $bsz = Draw-Base $g $draw $big $bigFont $bc $x0 $bb
        $bx = $x0 + $bsz.Width + (S 3)
        if ($unit) {
            $usz = Draw-Base $g $draw $unit $Fonts.BigUnit $t.Secondary $bx $bb
            $bx += $usz.Width + (S 8)
        } else { $bx += S 6 }
        $rightW = 0
        if ($main.Reset) {
            $rv = [string]$main.Reset
            $rightW = [math]::Max((Measure-Str $rv $Fonts.MonoV).Width, (Measure-Str 'resets in' $Fonts.Small).Width)
            [void](Draw-Base $g $draw $rv $Fonts.MonoV $t.Primary $xr $bb 'right')
            [void](Draw-Base $g $draw 'resets in' $Fonts.Small $t.Faint $xr ($bb - (S 17)) 'right')
        }
        if ($after) {
            $aw = $xr - $rightW - (S 12) - $bx
            if ($aw -gt (S 30)) { [void](Draw-Base $g $draw (Fit-Str $after $Fonts.Unit $aw) $Fonts.Unit $t.Secondary $bx $bb) }
        }
        $y = $bb

        # graduated meter: 4px track, ticks at 25/50/75/100% hanging below it
        if ($null -ne $pct) {
            $my = $y + (S 12)
            if ($draw) {
                Fill-Rect $g $t.Track $x0 $my $inner (S 4)
                if ($pct -gt 0) { Fill-Rect $g (Get-LevelColor $pct) $x0 $my ([math]::Max((S 2), [math]::Round($inner * $pct / 100))) (S 4) }
                foreach ($f in 0.25, 0.5, 0.75, 1.0) {
                    $tx = [math]::Round($x0 + $inner * $f) - $(if ($f -eq 1.0) { 1 } else { 0 })
                    Fill-Rect $g $t.Tick $tx ($my + (S 6)) 1 (S 4)
                }
            }
            $y = $my + (S 10)
        } else {
            $y += S 6
        }
    }

    # --- the other windows as a table: label · mini bar · % · reset (one baseline per row) ---
    $rows = @(); $texts = @(); $notes = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $mi) { continue }
        $ln = $lines[$i]
        if ($null -ne $ln.Pct) { $rows += $ln }
        elseif (Test-NoteLine $ln) { $notes += $ln }
        else { $texts += $ln }
    }
    if ($rows.Count) {
        $hasReset = $false
        foreach ($ln in $rows) { if ($ln.Reset) { $hasReset = $true } }
        $resetW = 0
        if ($hasReset) { foreach ($ln in $rows) { if ($ln.Reset) { $resetW = [math]::Max($resetW, (Measure-Str ([string]$ln.Reset) $Fonts.Mono).Width) } } }
        $resetW = [math]::Min([math]::Max($resetW, (S 56)), (S 90))
        $pctR = $xr - $(if ($hasReset) { $resetW + (S 10) } else { 0 })
        $pctW = S 36
        $barW = S 56
        $barX = $pctR - $pctW - (S 8) - $barW
        $labW = $barX - (S 10) - $x0
        $rb = $y + (S 14) + (Get-Cap $Fonts.Label)
        foreach ($ln in $rows) {
            $p2 = [math]::Max(0, [math]::Min(100, [double]$ln.Pct))
            [void](Draw-Base $g $draw (Fit-Str ([string]$ln.Label) $Fonts.Label $labW) $Fonts.Label $t.Secondary $x0 $rb)
            if ($draw) {
                $by = [math]::Round($rb - (Get-Cap $Fonts.Label) / 2 - (S 1.5))
                Fill-Rect $g $t.Track $barX $by $barW (S 3)
                if ($p2 -gt 0) { Fill-Rect $g (Get-LevelColor $p2) $barX $by ([math]::Max((S 2), [math]::Round($barW * $p2 / 100))) (S 3) }
            }
            if ($ln.Warn) { $vc = $t.BadFg } else { $vc = Get-LevelText $p2 }
            [void](Draw-Base $g $draw ('{0}%' -f [int][math]::Round([double]$ln.Pct)) $Fonts.Value $vc $pctR $rb 'right')
            if ($ln.Reset) { [void](Draw-Base $g $draw (Fit-Str ([string]$ln.Reset) $Fonts.Mono $resetW) $Fonts.Mono $t.Faint $xr $rb 'right') }
            $y = $rb + (S 4)
            $rb += S 22
        }
    }

    # --- money / counters under a dashed rule ---
    if ($texts.Count) {
        if ($main -or $rows.Count) {
            $ry = $y + (S 12)
            if ($draw) { Draw-Rule $g $t.Dash $x0 $xr $ry -Dashed }
            $y = $ry
        }
        $tb = $y + (S 12) + (Get-Cap $Fonts.Small)
        foreach ($ln in $texts) {
            $val = [string]$ln.Text
            if ($ln.Warn) { $vc = $t.BadFg } else { $vc = $t.Primary }
            $vsz = Measure-Str $val $Fonts.MonoV
            $labW = $inner - $vsz.Width - (S 10)
            if ($labW -lt (S 50)) {
                $h = Draw-Wrapped $g $draw (([string]$ln.Label) + ': ' + $val) $Fonts.Small $vc $x0 ($tb - (Get-Ascent $Fonts.Small)) $inner
                $y = $tb - (Get-Ascent $Fonts.Small) + $h
                $tb = $y + (S 8) + (Get-Cap $Fonts.Small)
                continue
            }
            [void](Draw-Base $g $draw (Fit-Str ([string]$ln.Label) $Fonts.Small $labW) $Fonts.Small $t.Secondary $x0 $tb)
            [void](Draw-Base $g $draw $val $Fonts.MonoV $vc $xr $tb 'right')
            $y = $tb + (S 4)
            $tb += S 20
        }
    }

    if ($notes.Count) {
        $y += S 10
        foreach ($ln in $notes) {
            if ($ln.Warn) { $nc = $t.BadFg } else { $nc = $t.Faint }
            $h = Draw-Wrapped $g $draw (([string]$ln.Label) + ': ' + ([string]$ln.Text)) $Fonts.Note $nc $x0 $y $inner
            $y += $h + (S 2)
        }
        $y -= S 4
    }
    ($y + (S 14)) - $top
}

function Get-WidgetWidth { if ($script:cfg.compact) { return (S 240) }; $WidgetW }

# Compact mode: one row per service (name · bar · value) plus any other window at 80%+.
function Paint-Compact($g, [bool]$draw) {
    $t = Get-Theme
    $w = [single](Get-WidgetWidth)
    $pad = S 14
    $xr = $w - $pad
    $nameW = S 64
    $valW = S 42
    $rowH = S 26
    $bx = $pad + $nameW + (S 8); $bw = $xr - $valW - (S 8) - $bx
    $y = S 6
    if ($null -eq $script:results) { $res = @() } else { $res = @($script:results) }
    if ($res.Count -eq 0) {
        [void](Draw-Base $g $draw 'AI Limits · loading…' $Fonts.Small $t.Secondary $pad ($y + $rowH / 2 + (Get-Cap $Fonts.Small) / 2))
        $y += $rowH
    }
    $first = $true
    foreach ($r in $res) {
        if (-not $first) {
            if ($draw) { Draw-Rule $g $t.Rule $pad $xr ($y + (S 3)) }
            $y += S 7
        }
        $first = $false
        $lines = @($r.Lines)
        $mi = -1; if (-not $r.Error) { $mi = Get-MainLineIndex $lines }
        $base = $y + $rowH / 2 + (Get-Cap $Fonts.Value) / 2
        if ($r.Status -and $draw) {
            $sc = Get-StatusColor $r
            Fill-Rect $g $sc[0] ($pad - (S 9)) ($y + $rowH / 2 - (S 2)) (S 5) (S 5)
        }
        $nm = (Split-Name ([string]$r.Name))[0]
        [void](Draw-Base $g $draw (Fit-Str $nm $Fonts.Value $nameW) $Fonts.Value $t.Primary $pad $base)
        $pct = $null
        if ($r.Error) { $val = '!'; $vc = $t.BadFg }
        elseif ($mi -ge 0 -and $null -ne $lines[$mi].Pct) { $pct = [math]::Max(0, [math]::Min(100, [double]$lines[$mi].Pct)); $val = '{0}%' -f [int][math]::Round([double]$lines[$mi].Pct); $vc = Get-LevelText $pct }
        elseif ($mi -ge 0) { $val = ([string]$lines[$mi].Text) -replace '\s+of\s+.*$', ''; $vc = $t.Primary }
        else { $val = '—'; $vc = $t.Faint }
        [void](Draw-Base $g $draw $val $Fonts.Value $vc $xr $base 'right')
        if ($null -ne $pct -and $draw) {
            $by = [math]::Round($y + $rowH / 2 - (S 1.5))
            Fill-Rect $g $t.Track $bx $by $bw (S 3)
            if ($pct -gt 0) { Fill-Rect $g (Get-LevelColor $pct) $bx $by ([math]::Max((S 2), [math]::Round($bw * $pct / 100))) (S 3) }
        }
        $y += $rowH
        if (-not $r.Error) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($i -eq $mi -or $null -eq $lines[$i].Pct -or [double]$lines[$i].Pct -lt 80) { continue }
                $p2 = [math]::Min(100, [double]$lines[$i].Pct)
                $base = $y + $rowH / 2 + (Get-Cap $Fonts.Value) / 2
                [void](Draw-Base $g $draw (Fit-Str ([string]$lines[$i].Label) $Fonts.Small $nameW) $Fonts.Small $t.Secondary $pad $base)
                [void](Draw-Base $g $draw ('{0}%' -f [int][math]::Round($p2)) $Fonts.Value (Get-LevelText $p2) $xr $base 'right')
                if ($draw) {
                    $by = [math]::Round($y + $rowH / 2 - (S 1.5))
                    Fill-Rect $g $t.Track $bx $by $bw (S 3)
                    Fill-Rect $g (Get-LevelColor $p2) $bx $by ([math]::Round($bw * $p2 / 100)) (S 3)
                }
                $y += $rowH
            }
        }
    }
    $h = [int]($y + (S 6))
    if ($draw) {
        if ($script:maskG) { Fill-Round $script:maskG ([System.Drawing.Color]::White) 0 0 $w $h (S $Radius.Compact) }
        Draw-PanelBorder $g $w $h (S $Radius.Compact)
    }
    $h
}

function Paint-Widget($g, [bool]$draw) {
    $t = Get-Theme
    $script:btns = @()
    if ($script:cfg.compact) { return (Paint-Compact $g $draw) }
    $w = [single]$WidgetW
    $y = 0

    # header: tracked caps title and update time on one baseline, four ghost icon buttons
    $hh = S 44
    $hb = [single]([math]::Round($hh / 2 + (Get-Cap $Fonts.Title) / 2))
    $tw = Draw-Tracked $g $draw 'AI LIMITS' $Fonts.Title $t.Primary (S 16) $hb ([single]($Fonts.Title.Size * 0.14))
    $st = [string]$script:statusText -replace '^Updated\s+', ''
    $stx = (S 16) + $tw + (S 10)
    [void](Draw-Base $g $draw (Fit-Str $st $Fonts.Mono ($w - $stx - (S 136))) $Fonts.Mono $t.Faint $stx $hb)
    $bs = S 30; $by = [math]::Round(($hh - $bs) / 2); $bx = $w - (S 8) - $bs
    Draw-IconButton $g $draw 'hide' '' 'Hide to tray (exit from the tray icon menu)' $bx $by $bs
    $bx -= $bs + (S 2)
    Draw-IconButton $g $draw 'settings' '' 'Settings' $bx $by $bs
    $bx -= $bs + (S 2)
    Draw-IconButton $g $draw 'refresh' '' 'Refresh now' $bx $by $bs
    $bx -= $bs + (S 2)
    Draw-IconButton $g $draw 'stats' '' 'Statistics and charts' $bx $by $bs
    $y += $hh
    if ($draw) { Draw-Rule $g $t.Rule 0 $w ($y - 1) }

    $res = $script:results
    if ($null -eq $res -or @($res).Count -eq 0) {
        if ($null -eq $res) { $msg = 'Loading…' } else { $msg = 'No services yet. Open Settings to add one.' }
        $mh = Draw-Wrapped $g $draw $msg $Fonts.Note $t.Secondary (S 16) ($y + (S 16)) ($w - (S 32))
        $y += $mh + (S 32)
    } else {
        $first = $true
        foreach ($r in @($res)) {
            if (-not $first -and $draw) { Draw-Rule $g $t.Rule 0 $w ($y - 1) }
            $first = $false
            $ch = Layout-Card $g $draw $r $y $w
            $y += $ch
        }
    }
    $h = [int][math]::Ceiling($y)
    if ($draw) {
        Add-CardShape 0 $w $h
        Draw-PanelBorder $g $w $h (S $Radius.Card)
    }
    $h
}

# Renders the widget into an ARGB image and hands it to Windows (per-pixel alpha).
function Update-Visual {
    $t = Get-Theme
    $WW = Get-WidgetWidth
    if ($script:suppressed) {
        # a game or fullscreen app is on this monitor: fully transparent and click-through
        $hh0 = [math]::Max(1, $form.Height)
        $blank = New-Object System.Drawing.Bitmap($WW, $hh0, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [AILimitsUI.Layered]::Apply($form.Handle, $blank, $form.Left, $form.Top)
        $blank.Dispose()
        return
    }
    $h = [math]::Max((S 40), (Paint-Widget $null $false))
    $content = New-Object System.Drawing.Bitmap($WW, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
    $mask = New-Object System.Drawing.Bitmap($WW, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($content)
    $mg = [System.Drawing.Graphics]::FromImage($mask)
    try {
        $g.Clear($t.Card)
        $bd = [AILimitsUI.Glass]::Backdrop($form.Handle, $form.Left, $form.Top, $WW, $h)
        if ($bd) {
            $g.DrawImageUnscaled($bd, 0, 0)
            $bd.Dispose()
            $veil = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($t.Opacity, $t.Card))
            $g.FillRectangle($veil, 0, 0, $WW, $h)
            $veil.Dispose()
        }
        $g.SmoothingMode = 'AntiAlias'
        $g.PixelOffsetMode = 'HighQuality'
        $mg.Clear([System.Drawing.Color]::Transparent)
        $mg.SmoothingMode = 'AntiAlias'
        $mg.PixelOffsetMode = 'HighQuality'
        $script:maskG = $mg
        [void](Paint-Widget $g $true)
        $script:maskG = $null
        $argb = [AILimitsUI.Layered]::Compose($content, $mask)
        if ($form.Width -ne $WW -or $form.Height -ne $h) { $form.Size = New-Object System.Drawing.Size($WW, $h) }
        [AILimitsUI.Layered]::Apply($form.Handle, $argb, $form.Left, $form.Top)
        $argb.Dispose()
    } finally {
        $script:maskG = $null
        $g.Dispose(); $mg.Dispose(); $content.Dispose(); $mask.Dispose()
    }
}

function Update-Layout { Update-Visual }

function Get-ButtonAt([int]$x, [int]$y) {
    foreach ($b in $script:btns) { if ($b.Rect.Contains([single]$x, [single]$y)) { return $b } }
    $null
}

$form.Add_MouseMove({
    $b = Get-ButtonAt $_.X $_.Y
    $act = $null; if ($b) { $act = $b.Action }
    if ($act -ne $script:hover) {
        $script:hover = $act
        if ($b) { $form.Cursor = [System.Windows.Forms.Cursors]::Hand; $tooltip.SetToolTip($form, $b.Tip) }
        else { $form.Cursor = [System.Windows.Forms.Cursors]::Default; $tooltip.SetToolTip($form, '') }
        Update-Visual
    }
})
$form.Add_MouseLeave({ if ($script:hover) { $script:hover = $null; Update-Visual } })
$form.Add_MouseDown({
    if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $b = Get-ButtonAt $_.X $_.Y
    if ($b) { $script:pressed = $b.Action; return }
    $tick = [Environment]::TickCount
    if (($tick - $script:lastDown) -lt [System.Windows.Forms.SystemInformation]::DoubleClickTime) { $script:lastDown = 0; Toggle-Compact; return }
    $script:lastDown = $tick
    [void][AILimits.Native]::ReleaseCapture()
    [void][AILimits.Native]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
    $script:cfg.x = $form.Left; $script:cfg.y = $form.Top
    Save-Config
    Update-Visual
})
$form.Add_MouseUp({
    $b = Get-ButtonAt $_.X $_.Y
    $act = $script:pressed
    $script:pressed = $null
    if (-not $b -or $b.Action -ne $act) { return }
    switch ($act) {
        'refresh' { Start-Refresh -Force }
        'settings' { Show-Settings }
        'stats' { Show-Stats }
        'hide' { $form.Hide() }
    }
})

function Keep-OnScreen {
    $wa = [System.Windows.Forms.Screen]::FromPoint($form.Location).WorkingArea
    if ($script:firstPlace) {
        $form.Left = $wa.Right - $form.Width - (S 16)
        $form.Top = $wa.Bottom - $form.Height - (S 16)
        return
    }
    $x = [math]::Max($wa.Left, [math]::Min($form.Left, $wa.Right - $form.Width))
    $y = [math]::Max($wa.Top, [math]::Min($form.Top, $wa.Bottom - $form.Height))
    $form.Location = New-Object System.Drawing.Point($x, $y)
}

function Set-TrayIcon([string]$text, $color, $textColor) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, 0, 0, 31, 31)
    if ($text.Length -ge 3) { $size = 15 } else { $size = 19 }
    [AILimitsUI.Icons]::TextCentered($g, $text, 'Segoe UI', [System.Drawing.FontStyle]::Bold, $size, $textColor, (New-Object System.Drawing.RectangleF(0, 0, 31, 31)))
    $h = $bmp.GetHicon()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($h)
    if ($script:hIcon -ne [IntPtr]::Zero) { [void][AILimits.Native]::DestroyIcon($script:hIcon) }
    $script:hIcon = $h
    $brush.Dispose(); $g.Dispose(); $bmp.Dispose()
}

function Update-Tray($results) {
    $t = Get-Theme
    $main = $null
    foreach ($r in @($results)) { if ($null -ne $r.Main) { $main = [double]$r.Main; break } }
    if ($null -ne $main) {
        Set-TrayIcon ([string][int][math]::Round($main)) (Get-LevelColor $main) ([System.Drawing.Color]::White)
    } else {
        Set-TrayIcon 'AI' $t.Ink ([System.Drawing.Color]::White)
    }
    $tips = @()
    foreach ($r in @($results)) {
        if ($r.Error) { $tips += ($r.Name + ': error') }
        elseif (@($r.Lines).Count -gt 0) { $tips += ($r.Name + ': ' + @($r.Lines)[0].Text) }
    }
    $tip = ($tips -join "`n")
    if (-not $tip) { $tip = $AppName }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + '…' }
    $notify.Text = $tip
}

function Render-Results($results) {
    $script:results = $results
    if ($null -ne $results) { $script:statusText = 'Updated ' + (Get-Date -Format 'HH:mm') }
    Update-Layout
    if ($null -ne $results) { Update-Tray $results }
    Keep-OnScreen
    if ($null -ne $results -and $script:firstPlace) {
        $script:firstPlace = $false
        $script:cfg.x = $form.Left; $script:cfg.y = $form.Top
        Save-Config
    }
}

function Start-Refresh([switch]$Force) {
    if ($script:job) { $script:pendingRefresh = $true; if ($Force) { $script:pendingForce = $true }; return }
    $script:statusText = 'Refreshing…'
    Update-Visual
    $list = @()
    foreach ($p in $script:cfg.providers) {
        $o = New-Object PSObject
        foreach ($k in $p.Keys) { if ($k -ne 'key' -and $k -ne 'webKey') { $o | Add-Member -NotePropertyName $k -NotePropertyValue $p[$k] } }
        $o | Add-Member -NotePropertyName plainKey -NotePropertyValue (Unprotect-Text ([string]$p.key))
        $o | Add-Member -NotePropertyName plainWebKey -NotePropertyValue (Unprotect-Text ([string]$p.webKey))
        $o | Add-Member -NotePropertyName force -NotePropertyValue ([bool]$Force) -Force
        $list += $o
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($FetchScript).AddArgument($list).AddArgument($CdpCode)
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

# The poll timer keeps ticking while a dialog is open, so the finished job is taken
# off $script:job first and the function refuses to re-enter itself.
function Check-Job {
    if ($script:inCheck) { return }
    if (-not $script:job -or -not $script:job.Handle.IsCompleted) { return }
    $script:inCheck = $true
    $job = $script:job
    $script:job = $null
    $res = @()
    $ask = @()
    try {
        try {
            $res = @($job.PS.EndInvoke($job.Handle))
            foreach ($e in $job.PS.Streams.Error) { Write-Log "fetch: $e" }
        } catch {
            Write-Log "fetch fatal: $_"
        } finally {
            $job.PS.Dispose()
        }
        $renewed = $false
        foreach ($rr in $res) {
            if ($rr.NewWebKey) {
                foreach ($pp in $script:cfg.providers) { if ($pp.id -eq $rr.Id) { $pp['webKey'] = Protect-Text ([string]$rr.NewWebKey); $renewed = $true } }
            }
            if ($rr.AskRefresh) { $ask += $rr.Id }
        }
        if ($renewed) { Save-Config }
        Render-Results $res

        # ask about renewing the Claude Code sign-in at most once per provider
        foreach ($id in $ask) {
            foreach ($pp in $script:cfg.providers) {
                if ($pp.id -ne $id -or $pp.Contains('autoRefresh')) { continue }
                $msg = "The Claude Code sign-in on this PC has expired, so AI Limits cannot read your Claude limits from it.`n`nAllow AI Limits to renew it automatically (only while Claude Code is not running)? It does what Claude Code does itself and writes the new token to %USERPROFILE%\.claude\.credentials.json, keeping a backup copy.`n`nYou can change this later in Settings."
                $pp['autoRefresh'] = $false   # recorded before the dialog, so it can never be asked twice
                $ans = [System.Windows.Forms.MessageBox]::Show($msg, $AppName, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                $pp['autoRefresh'] = ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
                Save-Config
                if ($pp['autoRefresh']) { $script:pendingRefresh = $true }
            }
        }
    } finally {
        $script:inCheck = $false
    }
    if ($script:pendingRefresh) {
        $script:pendingRefresh = $false
        $pf = [bool]$script:pendingForce; $script:pendingForce = $false
        Start-Refresh -Force:$pf
    }
}

function Toggle-Window {
    if ($form.Visible) { $form.Hide() } else { $form.Show(); $form.Activate() }
}

function Exit-App {
    $script:exiting = $true
    $script:cfg.x = $form.Left; $script:cfg.y = $form.Top
    Save-Config
    $notify.Visible = $false
    $form.Close()
}
# ---------- settings ----------
$FieldDefs = [ordered]@{
    name      = 'Name'
    key       = 'Key'
    webKey    = 'sessionKey claude.ai'
    configDir = 'Account folder (opt.)'
    planPrice = 'Plan price, $/month'
    budget    = 'Budget, $ per month'
    url       = 'URL'
    header    = 'Header'
    valuePath = 'Remaining value path'
    totalPath = 'Total value path (opt.)'
    unit      = 'Currency / unit'
}

function Update-SettingsList {
    $ui = $script:ui
    $sel = $ui.List.SelectedIndex
    $script:loadingFields = $true
    $ui.List.BeginUpdate()
    $ui.List.Items.Clear()
    foreach ($it in $script:edit) {
        $n = [string]$it.name
        if (-not $n) { $n = '(unnamed)' }
        [void]$ui.List.Items.Add($n)
    }
    $ui.List.EndUpdate()
    $script:loadingFields = $false
    if ($sel -ge $ui.List.Items.Count) { $sel = $ui.List.Items.Count - 1 }
    $ui.List.SelectedIndex = $sel
    if ($sel -lt 0) { Show-SettingsItem }
    $ui.List.Invalidate()
}

# a white input with a 1px border and inner padding (WinForms TextBox borders are too tight)
function New-FieldBox([int]$w) {
    $pn = New-Object System.Windows.Forms.Panel
    $pn.Size = New-Object System.Drawing.Size($w, (S 32))
    $pn.BackColor = $DlgColors.Field
    $pn.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($DlgColors.FieldBorder, 1)
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
        $pen.Dispose()
    })
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'None'
    $tb.BackColor = $DlgColors.Field
    $tb.ForeColor = $DlgColors.Text
    $tb.Font = $DlgFonts.Body
    $tb.Location = New-Object System.Drawing.Point((S 9), [int](((S 32) - $tb.PreferredHeight) / 2))
    $tb.Width = $w - (S 18)
    $tb.Anchor = 'Left, Right, Top'
    $pn.Controls.Add($tb)
    $pn.Tag = $tb
    $pn.Add_Click({ $this.Tag.Focus() })
    @{ Frame = $pn; Box = $tb }
}

function New-Hairline($parent, [int]$x, [int]$y, [int]$w, [int]$h = 1) {
    $l = New-Object System.Windows.Forms.Label
    $l.BackColor = $DlgColors.Rule
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $parent.Controls.Add($l)
    $l
}

function New-CapsLabel($parent, [string]$text, [int]$x, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text.ToUpperInvariant()
    $l.Font = $DlgFonts.Caps
    $l.ForeColor = $DlgColors.Faint
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $parent.Controls.Add($l)
    $l
}

$WideFields = @('key', 'webKey', 'configDir', 'url', 'header', 'valuePath')

function Show-SettingsItem {
    $ui = $script:ui
    $i = $ui.List.SelectedIndex
    $script:loadingFields = $true
    $ui.Main.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    $x0 = $ui.X0; $cw = $ui.CW
    $hideAll = {
        foreach ($f in $FieldDefs.Keys) { $ui.Labels[$f].Visible = $false; $ui.Frames[$f].Visible = $false }
        $ui.Cents.Visible = $false
        $ui.AutoRefresh.Visible = $false
        $ui.BtnWeb.Visible = $false; $ui.BtnCli.Visible = $false; $ui.BtnBridge.Visible = $false
        $ui.ActLabel.Visible = $false
    }
    if ($i -lt 0) {
        $ui.Title.Text = 'No services yet'
        $ui.TypeLabel.Text = 'Use "+ Add service" or "Connect automatically…" on the left.'
        $ui.Hint.Text = ''
        $ui.BtnDel.Visible = $false
        & $hideAll
        $script:loadingFields = $false
        return
    }
    $ui.BtnDel.Visible = $true
    $it = $script:edit[$i]
    $t = $Types[[string]$it.type]
    $nm = [string]$it.name; if (-not $nm) { $nm = '(unnamed)' }
    $ui.Title.Text = $nm
    $ui.TypeLabel.Text = $t.Title
    $hint = $t.Hint
    if ($it.key -or $it.webKey) { $hint += ' Saved keys are hidden — leave the field empty to keep them.' }
    $ui.Hint.Text = $hint
    $hs = [System.Windows.Forms.TextRenderer]::MeasureText($hint, $ui.Hint.Font, (New-Object System.Drawing.Size($cw, 2000)), [System.Windows.Forms.TextFormatFlags]'WordBreak, NoPrefix')
    $ui.Hint.Height = $hs.Height + (S 4)
    $y = $ui.Hint.Top + $ui.Hint.Height + (S 16)

    $half = [int](($cw - (S 16)) / 2)
    $leftOpen = $false
    foreach ($f in $FieldDefs.Keys) {
        $show = ($f -eq 'name') -or ($t.Fields -contains $f)
        $ui.Labels[$f].Visible = $show
        $ui.Frames[$f].Visible = $show
        if ($f -eq 'key') { $ui.Labels[$f].Text = $t.KeyLabel; $ui.Boxes[$f].Text = [string]$it.newKey }
        elseif ($f -eq 'webKey') { $ui.Boxes[$f].Text = [string]$it.newWebKey }
        else { $ui.Boxes[$f].Text = [string]$it[$f] }
        if (-not $show) { continue }
        $wide = $WideFields -contains $f
        if ($wide) {
            if ($leftOpen) { $y += S 60; $leftOpen = $false }
            $fx = $x0; $fw = $cw
        } elseif ($leftOpen) {
            $fx = $x0 + $half + (S 16); $fw = $half
        } else {
            $fx = $x0; $fw = $half
        }
        $ui.Labels[$f].Location = New-Object System.Drawing.Point($fx, $y)
        $ui.Frames[$f].Location = New-Object System.Drawing.Point($fx, ($y + (S 20)))
        $ui.Frames[$f].Width = $fw
        if ($wide) { $y += S 60 }
        elseif ($leftOpen) { $y += S 60; $leftOpen = $false }
        else { $leftOpen = $true }
    }
    if ($leftOpen) { $y += S 60 }

    $ui.Cents.Visible = ($t.Fields -contains 'cents')
    $ui.Cents.Checked = [bool]$it.cents
    $ui.Cents.Top = $y
    $ui.AutoRefresh.Visible = ($t.Fields -contains 'autoRefresh')
    $ui.AutoRefresh.Checked = ($it.autoRefresh -eq $true)
    $ui.AutoRefresh.Top = $y
    if ($ui.AutoRefresh.Visible -or $ui.Cents.Visible) { $y += S 34 }

    # account actions: sign-ins and bridge for exactly this account
    $isClaude = ($it.type -eq 'claude-code'); $isCodex = ($it.type -eq 'codex')
    $ui.BtnWeb.Visible = $isClaude; $ui.BtnCli.Visible = ($isClaude -or $isCodex); $ui.BtnBridge.Visible = $isClaude
    $ui.ActLabel.Visible = ($isClaude -or $isCodex)
    if ($isCodex) { $ui.BtnCli.Text = 'Codex sign-in…' } else { $ui.BtnCli.Text = 'Claude Code sign-in…' }
    if ($ui.ActLabel.Visible) {
        $y += S 6
        $ui.ActLabel.Top = $y
        $y += S 22
        $bx = $x0
        foreach ($b in @($ui.BtnWeb, $ui.BtnCli, $ui.BtnBridge)) {
            if (-not $b.Visible) { continue }
            $b.Top = $y; $b.Left = $bx; $bx += $b.Width + (S 8)
        }
        $y += S 34
    }
    $ui.Spacer.Top = $y + (S 16)
    $script:loadingFields = $false
}

function Get-SettingsDot($it) {
    foreach ($r in @($script:results)) {
        if ($null -eq $r -or $r.Id -ne $it.id) { continue }
        if ($r.Error) { return $Glass.Bad }
        if ($r.Status) { return $Glass.Warn }
        return $Glass.Ok
    }
    $DlgColors.FieldBorder
}

function Show-Settings {
    if ($script:settingsOpen) { return }
    $script:settingsOpen = $true
    try {
        $script:edit = New-Object System.Collections.ArrayList
        foreach ($p in $script:cfg.providers) {
            $h = [ordered]@{}
            foreach ($k in $p.Keys) { $h[$k] = $p[$k] }
            $h['newKey'] = ''
            $h['newWebKey'] = ''
            [void]$script:edit.Add($h)
        }
        $script:ui = @{ Labels = @{}; Boxes = @{}; Frames = @{} }
        $ui = $script:ui

        $FormW = S 780; $FormH = S 600; $SideW = S 230; $FootY = S 484
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'AI Limits — Settings'
        $f.FormBorderStyle = 'FixedDialog'
        $f.MaximizeBox = $false; $f.MinimizeBox = $false
        $f.StartPosition = 'CenterScreen'
        $f.ShowIcon = $false
        $f.TopMost = $false
        $f.Font = $DlgFonts.Body
        $f.ClientSize = New-Object System.Drawing.Size($FormW, $FormH)
        $ui.Form = $f

        # ---- left: services ----
        $side = New-Object System.Windows.Forms.Panel
        $side.Location = New-Object System.Drawing.Point(0, 0)
        $side.Size = New-Object System.Drawing.Size($SideW, $FootY)
        $side.BackColor = $DlgColors.Side
        $f.Controls.Add($side)
        [void](New-Hairline $f $SideW 0 1 $FootY)
        [void](New-CapsLabel $side 'Services' (S 18) (S 18))

        $lb = New-Object System.Windows.Forms.ListBox
        $lb.Location = New-Object System.Drawing.Point((S 10), (S 40))
        $lb.Size = New-Object System.Drawing.Size(($SideW - (S 20)), (S 330))
        $lb.IntegralHeight = $false
        $lb.BorderStyle = 'None'
        $lb.BackColor = $DlgColors.Side
        $lb.DrawMode = 'OwnerDrawFixed'
        $lb.ItemHeight = S 34
        $lb.Add_DrawItem({
            param($s, $e)
            if ($e.Index -lt 0) { return }
            $g = $e.Graphics
            $g.SmoothingMode = 'AntiAlias'
            $bgb = New-Object System.Drawing.SolidBrush($DlgColors.Side)
            $g.FillRectangle($bgb, $e.Bounds); $bgb.Dispose()
            $selected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
            $b = $e.Bounds
            if ($selected) {
                $p = New-RoundPath ([single]$b.X) ([single]($b.Y + 1)) ([single]($b.Width - 1)) ([single]($b.Height - 2)) ([single](S $Radius.Btn))
                $sb = New-Object System.Drawing.SolidBrush($DlgColors.Dark); $g.FillPath($sb, $p); $sb.Dispose(); $p.Dispose()
                $fc = [System.Drawing.Color]::White
            } else { $fc = $DlgColors.Text }
            $txt = [string]$s.Items[$e.Index]
            $tr = New-Object System.Drawing.Rectangle(($b.X + (S 10)), $b.Y, ($b.Width - (S 34)), $b.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $txt, $DlgFonts.Body, $tr, $fc, [System.Windows.Forms.TextFormatFlags]'VerticalCenter, SingleLine, EndEllipsis, NoPrefix')
            if ($e.Index -lt $script:edit.Count) {
                $dc = Get-SettingsDot $script:edit[$e.Index]
                $db = New-Object System.Drawing.SolidBrush($dc)
                $g.SmoothingMode = 'None'
                $g.FillRectangle($db, ($b.Right - (S 16)), ($b.Y + [int](($b.Height - (S 6)) / 2)), (S 6), (S 6)); $db.Dispose()
            }
        })
        $side.Controls.Add($lb)
        $ui.List = $lb
        $lb.Add_SelectedIndexChanged({ if (-not $script:loadingFields) { Show-SettingsItem }; $this.Invalidate() })

        $addMenu = New-Object System.Windows.Forms.ContextMenuStrip
        foreach ($tk in $Types.Keys) {
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem($Types[$tk].Title)
            $mi.Tag = $tk
            $mi.Add_Click({
                $np = New-Provider ([string]$this.Tag)
                $np['newKey'] = ''
                Set-DefaultProfile $np $script:edit
                [void]$script:edit.Add($np)
                $script:ui.List.SelectedIndex = -1
                Update-SettingsList
                $script:ui.List.SelectedIndex = $script:edit.Count - 1
            })
            [void]$addMenu.Items.Add($mi)
        }
        $btnAdd = New-Object AILimitsUI.RoundButton
        $btnAdd.Text = '+  Add service'
        $btnAdd.Location = New-Object System.Drawing.Point((S 10), (S 380))
        $btnAdd.Size = New-Object System.Drawing.Size(($SideW - (S 20)), (S 34))
        $btnAdd.Add_Click({ $script:ui.AddMenu.Show($this, (New-Object System.Drawing.Point(0, $this.Height))) })
        $side.Controls.Add($btnAdd)
        $ui.AddMenu = $addMenu

        $btnAuto = New-Object AILimitsUI.RoundButton
        $btnAuto.Text = 'Connect automatically…'
        $btnAuto.Location = New-Object System.Drawing.Point((S 10), (S 422))
        $btnAuto.Size = New-Object System.Drawing.Size(($SideW - (S 20)), (S 36))
        $btnAuto.Add_Click({ Show-AutoConnect })
        $side.Controls.Add($btnAuto)

        # ---- right: the selected service (scrolls if a type has many fields) ----
        $main = New-Object System.Windows.Forms.Panel
        $main.Location = New-Object System.Drawing.Point(($SideW + 1), 0)
        $main.Size = New-Object System.Drawing.Size(($FormW - $SideW - 1), $FootY)
        $main.AutoScroll = $true
        $main.BackColor = $DlgColors.Bg
        $f.Controls.Add($main)
        $ui.Main = $main
        $x0 = S 28
        $cw = $main.Width - 2 * $x0 - (S 10)
        $ui.X0 = $x0; $ui.CW = $cw

        $ui.Title = New-Object System.Windows.Forms.Label
        $ui.Title.Font = $DlgFonts.H1
        $ui.Title.AutoEllipsis = $true
        $ui.Title.Location = New-Object System.Drawing.Point($x0, (S 18))
        $ui.Title.Size = New-Object System.Drawing.Size(($cw - (S 90)), (S 30))
        $main.Controls.Add($ui.Title)

        $btnDel = New-Object AILimitsUI.RoundButton
        $btnDel.Text = 'Remove'
        $btnDel.AccessibleDescription = 'danger'
        $btnDel.Location = New-Object System.Drawing.Point(($x0 + $cw - (S 80)), (S 18))
        $btnDel.Size = New-Object System.Drawing.Size((S 80), (S 30))
        $btnDel.Add_Click({
            $i = $script:ui.List.SelectedIndex
            if ($i -ge 0) { $script:edit.RemoveAt($i); Update-SettingsList }
        })
        $main.Controls.Add($btnDel)
        $ui.BtnDel = $btnDel

        $ui.TypeLabel = New-Object System.Windows.Forms.Label
        $ui.TypeLabel.ForeColor = $DlgColors.Faint
        $ui.TypeLabel.Location = New-Object System.Drawing.Point($x0, (S 52))
        $ui.TypeLabel.Size = New-Object System.Drawing.Size($cw, (S 20))
        $main.Controls.Add($ui.TypeLabel)

        $ui.Hint = New-Object System.Windows.Forms.Label
        $ui.Hint.ForeColor = $DlgColors.Muted
        $ui.Hint.Location = New-Object System.Drawing.Point($x0, (S 80))
        $ui.Hint.Size = New-Object System.Drawing.Size($cw, (S 60))
        $main.Controls.Add($ui.Hint)

        foreach ($fk in $FieldDefs.Keys) {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $FieldDefs[$fk]
            $l.ForeColor = $DlgColors.Muted
            $l.AutoSize = $true
            $l.Location = New-Object System.Drawing.Point($x0, 0)
            $main.Controls.Add($l)
            $ui.Labels[$fk] = $l

            $fb = New-FieldBox $cw
            $tb = $fb.Box
            $tb.Tag = $fk
            if ($fk -eq 'key' -or $fk -eq 'webKey') { $tb.UseSystemPasswordChar = $true }
            if ($fk -in 'configDir', 'url', 'valuePath', 'totalPath', 'header') { $tb.Font = $DlgFonts.Mono }
            $tb.Add_TextChanged({
                if ($script:loadingFields) { return }
                $i = $script:ui.List.SelectedIndex
                if ($i -lt 0) { return }
                $fld = [string]$this.Tag
                if ($fld -eq 'key') { $script:edit[$i]['newKey'] = $this.Text }
                elseif ($fld -eq 'webKey') { $script:edit[$i]['newWebKey'] = $this.Text } else { $script:edit[$i][$fld] = $this.Text }
                if ($fld -eq 'name') { $script:ui.Title.Text = $this.Text }
            })
            if ($fk -eq 'name') { $tb.Add_Leave({ if ($script:ui.Form.Visible) { Update-SettingsList } }) }
            $fb.Frame.Location = New-Object System.Drawing.Point($x0, 0)
            $main.Controls.Add($fb.Frame)
            $ui.Boxes[$fk] = $tb
            $ui.Frames[$fk] = $fb.Frame
        }

        $ui.Cents = New-Object System.Windows.Forms.CheckBox
        $ui.Cents.Text = 'Report amounts are in cents (check vs Console)'
        $ui.Cents.Location = New-Object System.Drawing.Point($x0, 0)
        $ui.Cents.Size = New-Object System.Drawing.Size($cw, (S 26))
        $ui.Cents.Add_CheckedChanged({
            if ($script:loadingFields) { return }
            $i = $script:ui.List.SelectedIndex
            if ($i -ge 0) { $script:edit[$i]['cents'] = $this.Checked }
        })
        $main.Controls.Add($ui.Cents)

        $ui.AutoRefresh = New-Object System.Windows.Forms.CheckBox
        $ui.AutoRefresh.Text = 'Renew the Claude Code sign-in automatically'
        $ui.AutoRefresh.Location = New-Object System.Drawing.Point($x0, 0)
        $ui.AutoRefresh.Size = New-Object System.Drawing.Size($cw, (S 26))
        $ui.AutoRefresh.Add_CheckedChanged({
            if ($script:loadingFields) { return }
            $i = $script:ui.List.SelectedIndex
            if ($i -ge 0) { $script:edit[$i]['autoRefresh'] = $this.Checked }
        })
        $main.Controls.Add($ui.AutoRefresh)

        $ui.ActLabel = New-CapsLabel $main 'Sign-in and bridge' $x0 0
        foreach ($spec in @(@('BtnWeb', 'Sign in to claude.ai…', 160), @('BtnCli', 'Claude Code sign-in…', 160), @('BtnBridge', 'Bridge…', 96))) {
            $b = New-Object AILimitsUI.RoundButton
            $b.Text = $spec[1]
            $b.Tag = $spec[0]
            $b.Size = New-Object System.Drawing.Size((S $spec[2]), (S 32))
            $b.Location = New-Object System.Drawing.Point($x0, 0)
            $b.Visible = $false
            $b.Add_Click({
                $i = $script:ui.List.SelectedIndex
                if ($i -lt 0) { return }
                Invoke-AccountAction $script:edit[$i] ([string]$this.Tag)
            })
            $main.Controls.Add($b)
            $ui[$spec[0]] = $b
        }
        # keeps a little room under the last control when the panel scrolls
        $ui.Spacer = New-Object System.Windows.Forms.Label
        $ui.Spacer.Size = New-Object System.Drawing.Size(1, 1)
        $ui.Spacer.Location = New-Object System.Drawing.Point($x0, 0)
        $main.Controls.Add($ui.Spacer)

        # ---- bottom: general options, then Cancel / Save ----
        [void](New-Hairline $f 0 $FootY $FormW)
        $gy = $FootY + (S 18)
        $li = New-Object System.Windows.Forms.Label
        $li.Text = 'Refresh every'
        $li.ForeColor = $DlgColors.Muted
        $li.AutoSize = $true
        $li.Location = New-Object System.Drawing.Point((S 20), ($gy + (S 4)))
        $f.Controls.Add($li)

        $nudBox = New-FieldBox (S 52)
        $nud = $nudBox.Box
        $nud.Text = [string]([math]::Max(1, [math]::Min(120, [int]$script:cfg.interval)))
        $nud.TextAlign = 'Center'
        $nud.MaxLength = 3
        $nud.Add_KeyPress({ if (-not [char]::IsDigit($_.KeyChar) -and -not [char]::IsControl($_.KeyChar)) { $_.Handled = $true } })
        $nudBox.Frame.Location = New-Object System.Drawing.Point((S 112), ($gy - (S 3)))
        $f.Controls.Add($nudBox.Frame)

        $lm = New-Object System.Windows.Forms.Label
        $lm.Text = 'min'
        $lm.ForeColor = $DlgColors.Muted
        $lm.AutoSize = $true
        $lm.Location = New-Object System.Drawing.Point((S 168), ($gy + (S 4)))
        $f.Controls.Add($lm)

        $lh = New-Object System.Windows.Forms.Label
        $lh.Text = 'Hotkey'
        $lh.ForeColor = $DlgColors.Muted
        $lh.AutoSize = $true
        $lh.Location = New-Object System.Drawing.Point((S 214), ($gy + (S 4)))
        $f.Controls.Add($lh)

        $hkBox = New-FieldBox (S 110)
        $hk = $hkBox.Box
        $hk.Text = [string]$script:cfg.hotkey
        $hk.Font = $DlgFonts.Mono
        $hkBox.Frame.Location = New-Object System.Drawing.Point((S 262), ($gy - (S 3)))
        $f.Controls.Add($hkBox.Frame)

        $auto = New-Object System.Windows.Forms.CheckBox
        $auto.Text = 'Start with Windows'
        $auto.Location = New-Object System.Drawing.Point((S 400), ($gy - (S 1)))
        $auto.Size = New-Object System.Drawing.Size((S 160), (S 28))
        $auto.Checked = (Test-Path $StartupLnk)
        $f.Controls.Add($auto)

        $ah = New-Object System.Windows.Forms.CheckBox
        $ah.Text = 'Hide in games / fullscreen'
        $ah.Location = New-Object System.Drawing.Point((S 566), ($gy - (S 1)))
        $ah.Size = New-Object System.Drawing.Size((S 200), (S 28))
        $ah.Checked = [bool]$script:cfg.autoHide
        $f.Controls.Add($ah)

        [void](New-Hairline $f 0 ($FootY + (S 60)) $FormW)

        $ok = New-Object AILimitsUI.RoundButton
        $ok.Text = 'Save'
        $ok.Location = New-Object System.Drawing.Point(($FormW - (S 20) - (S 100)), ($FormH - (S 18) - (S 34)))
        $ok.Size = New-Object System.Drawing.Size((S 100), (S 34))
        $ok.DialogResult = 'OK'
        $f.Controls.Add($ok)
        $f.AcceptButton = $ok

        $cancel = New-Object AILimitsUI.RoundButton
        $cancel.Text = 'Cancel'
        $cancel.Location = New-Object System.Drawing.Point(($FormW - (S 20) - (S 100) - (S 8) - (S 100)), ($FormH - (S 18) - (S 34)))
        $cancel.Size = New-Object System.Drawing.Size((S 100), (S 34))
        $cancel.DialogResult = 'Cancel'
        $f.Controls.Add($cancel)
        $f.CancelButton = $cancel

        Set-DialogStyle $f @($ok, $btnAuto) @()
        foreach ($fr in @($ui.Frames.Values) + @($nudBox.Frame, $hkBox.Frame)) { $fr.BackColor = $DlgColors.Field; $fr.Tag.BackColor = $DlgColors.Field }
        Set-MenuStyle $addMenu
        $side.BackColor = $DlgColors.Side
        $lb.BackColor = $DlgColors.Side

        Update-SettingsList
        if ($script:edit.Count -gt 0) { $lb.SelectedIndex = 0 } else { Show-SettingsItem }

        if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $list = New-Object System.Collections.ArrayList
            foreach ($it in $script:edit) {
                if ($it['newKey']) { $it['key'] = Protect-Text ([string]$it['newKey']) }
                if ($it['newWebKey']) { $it['webKey'] = Protect-Text ([string]$it['newWebKey']) }
                $it.Remove('newKey'); $it.Remove('newWebKey')
                [void]$list.Add($it)
            }
            $script:cfg.providers = $list
            $iv = 5; [void][int]::TryParse($nud.Text, [ref]$iv)
            $script:cfg.interval = [math]::Max(1, [math]::Min(120, $iv))
            $script:cfg['hotkey'] = $hk.Text.Trim()
            $script:cfg['autoHide'] = $ah.Checked
            Register-AppHotKey
            Save-Config
            try { Set-Autostart $auto.Checked } catch { Write-Log "autostart: $_" }
            $refreshTimer.Interval = $script:cfg.interval * 60000
            Start-Refresh
        }
        $f.Dispose()
    } catch {
        Write-Log "settings: $_"
        [System.Windows.Forms.MessageBox]::Show("Settings error: $_", $AppName) | Out-Null
    } finally {
        $script:settingsOpen = $false
    }
}

# ---------- auto-connect ----------
$AutoDefs = [ordered]@{
    'claude-code' = @{
        Name = 'Claude (subscription)'; Kind = 'cli'; Exe = 'claude'; Extra = @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
        Install = 'irm https://claude.ai/install.ps1 | iex'; NeedsNode = $false; LoginArgs = ''
        InstallHint = 'The official Claude Code installer from Anthropic. No admin rights needed.'
        LoginHint = 'Claude Code will open. Choose to sign in with your Claude subscription (Pro/Max) and confirm in the browser. If it does not ask, type /login. Then you can close the window.'
    }
    'claude-bridge' = @{ Name = 'Claude — bridge with Claude Code in the terminal (exact, no 429 errors)'; Kind = 'bridge' }
    'claude-webkey' = @{ Name = 'Claude — via claude.ai (if you use the desktop app or browser)'; Kind = 'webkey' }
    'codex' = @{
        Name = 'ChatGPT (subscription, via Codex CLI)'; Kind = 'cli'; Exe = 'codex'; Extra = @((Join-Path $env:APPDATA 'npm\codex.cmd'))
        Install = 'npm install -g @openai/codex'; NeedsNode = $true; LoginArgs = 'login'
        InstallHint = 'OpenAI''s official terminal app (Codex CLI), installed via npm.'
        LoginHint = 'A browser will open — sign in to your ChatGPT account. Then you can close the window.'
    }
    'gemini' = @{
        Name = 'Gemini (via Gemini CLI, beta)'; Kind = 'cli'; Exe = 'gemini'; Extra = @((Join-Path $env:APPDATA 'npm\gemini.cmd'))
        Install = 'npm install -g @google/gemini-cli'; NeedsNode = $true; LoginArgs = ''
        InstallHint = 'Google''s official terminal app (Gemini CLI), installed via npm.'
        LoginHint = 'Gemini CLI will open. Choose "Login with Google" and sign in in the browser. Then type /quit or just close the window.'
    }
    'openrouter'    = @{ Name = 'OpenRouter'; Kind = 'key'; Env = 'OPENROUTER_API_KEY'; Url = 'https://openrouter.ai/settings/keys'; KeyHint = 'Click Create Key and copy the key (sk-or-…).' }
    'deepseek'      = @{ Name = 'DeepSeek'; Kind = 'key'; Env = 'DEEPSEEK_API_KEY'; Url = 'https://platform.deepseek.com/api_keys'; KeyHint = 'Click Create new API key and copy the key (sk-…).' }
    'anthropic-api' = @{ Name = 'Anthropic API'; Kind = 'key'; Env = 'ANTHROPIC_ADMIN_KEY'; Url = 'https://console.anthropic.com/settings/admin-keys'; KeyHint = 'Create an Admin key (sk-ant-admin…). Then set a monthly budget in Settings.' }
    'openai-api'    = @{ Name = 'OpenAI API'; Kind = 'key'; Env = 'OPENAI_ADMIN_KEY'; Url = 'https://platform.openai.com/settings/organization/admin-keys'; KeyHint = 'Create an Admin key (sk-admin…). Then set a monthly budget in Settings.' }
}

function Update-EnvPath {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

function Find-Exe([string]$name, $extra) {
    $cmdInfo = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmdInfo) { return $cmdInfo.Source }
    foreach ($xp in @($extra)) { if ($xp -and (Test-Path $xp)) { return $xp } }
    $null
}

function Get-AnyEnv([string]$n) {
    foreach ($scope in 'User', 'Machine', 'Process') {
        $v = [Environment]::GetEnvironmentVariable($n, $scope)
        if ($v) { return $v }
    }
    $null
}

function Test-CliLogin([string]$type) {
    try {
        switch ($type) {
            'claude-code' {
                if ($env:CLAUDE_CONFIG_DIR) { $d = $env:CLAUDE_CONFIG_DIR } else { $d = Join-Path $env:USERPROFILE '.claude' }
                return (Test-Path (Join-Path $d '.credentials.json'))
            }
            'codex' {
                if ($env:CODEX_HOME) { $d = $env:CODEX_HOME } else { $d = Join-Path $env:USERPROFILE '.codex' }
                $fp = Join-Path $d 'auth.json'
                if (-not (Test-Path $fp)) { return $false }
                $a = Get-Content $fp -Raw -Encoding UTF8 | ConvertFrom-Json
                return [bool]$a.tokens.access_token
            }
            'gemini' { return (Test-Path (Join-Path $env:USERPROFILE '.gemini\oauth_creds.json')) }
        }
    } catch {}
    $false
}

function Get-AutoStatus([string]$type) {
    $d = $AutoDefs[$type]
    if ($d.Kind -eq 'webkey') {
        if (Test-Path (Join-Path $AppDir 'browser')) {
            return @{ Text = 'signed in — limits are read through a background browser'; Color = $DlgColors.Ok; Button = 'Sign in again…'; Action = 'webkey' }
        }
        return @{ Text = 'sign in to claude.ai once in a separate browser window'; Color = $DlgColors.Warn; Button = 'Sign in…'; Action = 'webkey' }
    }
    if ($d.Kind -eq 'bridge') {
        if (Test-Bridge) { return @{ Text = 'connected — updates while you work in Claude Code'; Color = $DlgColors.Ok; Button = $null } }
        $cd = $AutoDefs['claude-code']
        if (-not (Test-CliLogin 'claude-code') -and -not (Find-Exe $cd.Exe $cd.Extra)) {
            return @{ Text = 'install Claude Code first (row above)'; Color = $DlgColors.Muted; Button = $null }
        }
        return @{ Text = 'Claude Code will send its limits here by itself'; Color = $DlgColors.Warn; Button = 'Connect…'; Action = 'bridge' }
    }
    foreach ($it in $script:edit) {
        if ($it.type -eq $type) { return @{ Text = 'already added'; Color = $DlgColors.Ok; Button = $null } }
    }
    if ($d.Kind -eq 'cli') {
        if (Test-CliLogin $type) { return @{ Text = 'sign-in found on this computer'; Color = $DlgColors.Ok; Button = 'Add'; Action = 'add' } }
        if (Find-Exe $d.Exe $d.Extra) { return @{ Text = 'installed, but not signed in'; Color = $DlgColors.Warn; Button = 'Sign in…'; Action = 'login' } }
        if ($d.NeedsNode -and -not (Find-Exe 'npm' @((Join-Path $env:ProgramFiles 'nodejs\npm.cmd')))) {
            return @{ Text = 'not installed; needs Node.js first'; Color = $DlgColors.Muted; Button = 'Install Node.js…'; Action = 'node' }
        }
        return @{ Text = 'not installed'; Color = $DlgColors.Muted; Button = 'Install…'; Action = 'install' }
    }
    if (Get-AnyEnv $d.Env) { return @{ Text = ('key found in variable ' + $d.Env); Color = $DlgColors.Ok; Button = 'Add'; Action = 'addenv' } }
    @{ Text = 'create the key on the website and paste it here'; Color = $DlgColors.Muted; Button = 'Get key…'; Action = 'getkey' }
}

function Add-EditProvider([string]$type, [string]$key) {
    $p = New-Provider $type
    $p['newKey'] = $key
    Set-DefaultProfile $p $script:edit
    [void]$script:edit.Add($p)
    Update-SettingsList
    $script:ui.List.SelectedIndex = $script:edit.Count - 1
}

function Confirm-AndRun([string]$title, [string]$explain, [string]$cmd) {
    $pathLine = "`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"
    $body = $pathLine + "`r`n" + $cmd

    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'; $d.ShowIcon = $false
    $d.Font = $DlgFonts.Body
    $d.ClientSize = New-Object System.Drawing.Size((S 640), (S 388))

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = $explain
    $l1.Location = New-Object System.Drawing.Point((S 14), (S 12))
    $l1.Size = New-Object System.Drawing.Size((S 612), (S 54))
    $d.Controls.Add($l1)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'Exactly this will run in a new PowerShell window:'
    $l2.Font = $DlgFonts.Btn
    $l2.Location = New-Object System.Drawing.Point((S 14), (S 72))
    $l2.Size = New-Object System.Drawing.Size((S 612), (S 20))
    $d.Controls.Add($l2)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.WordWrap = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Font = $DlgFonts.Mono
    $tb.BackColor = $DlgColors.Side
    $tb.Text = $body
    $tb.Location = New-Object System.Drawing.Point((S 14), (S 96))
    $tb.Size = New-Object System.Drawing.Size((S 612), (S 170))
    $d.Controls.Add($tb)

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'The first line only refreshes PATH so Windows sees newly installed programs right away. The window stays open so you can see the result and close it.'
    $l3.ForeColor = $DlgColors.Muted
    $l3.Location = New-Object System.Drawing.Point((S 14), (S 274))
    $l3.Size = New-Object System.Drawing.Size((S 612), (S 44))
    $d.Controls.Add($l3)

    $ok = New-Object AILimitsUI.RoundButton
    $ok.Text = 'Run'
    $ok.Location = New-Object System.Drawing.Point((S 426), (S 338))
    $ok.Size = New-Object System.Drawing.Size((S 100), (S 34))
    $ok.DialogResult = 'OK'
    $d.Controls.Add($ok)

    $no = New-Object AILimitsUI.RoundButton
    $no.Text = 'Cancel'
    $no.Location = New-Object System.Drawing.Point((S 534), (S 338))
    $no.Size = New-Object System.Drawing.Size((S 92), (S 34))
    $no.DialogResult = 'Cancel'
    $d.Controls.Add($no)
    $d.AcceptButton = $no
    $d.CancelButton = $no

    Set-DialogStyle $d @() @($ok)
    $res = $d.ShowDialog()
    $d.Dispose()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $full = $body + "`r`nWrite-Host ''`r`nWrite-Host 'Done. Close this window and return to AI Limits.' -ForegroundColor Green"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NoExit -ExecutionPolicy Bypass -EncodedCommand ' + $enc)
}

function Test-ClaudeWebKey([string]$k) {
    try {
        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'
        $null = Invoke-RestMethod -Uri 'https://claude.ai/api/organizations' -Headers @{ Cookie = "sessionKey=$k" } -UserAgent $ua -TimeoutSec 15 -UseBasicParsing
        return $true
    } catch { return $false }
}

function Step-WebKeyWait {
    $wk = $script:wk
    $wk.Timer.Stop()
    try {
        $wk.Ticks++
        $wsUrl = Get-CdpWsUrl $wk.Port
        if (-not $wsUrl) {
            if ($wk.Seen) { $wk.Label.Text = 'The browser window was closed before the key was found. Click Cancel and try again.'; return }
            if ($wk.Ticks -gt 20) { $wk.Label.Text = 'Cannot reach the browser. Close the window of this profile and try again.'; return }
            $wk.Timer.Start(); return
        }
        $wk.Seen = $true
        $k = Get-CdpSessionKey $wsUrl
        if ($k -and -not $wk.Tried.ContainsKey($k)) {
            $wk.Tried[$k] = 1
            $wk.Label.Text = 'Signed in — checking the key…'
            [System.Windows.Forms.Application]::DoEvents()
            if ($true) {
                $wk.Key = $k
                Close-CdpBrowser $wsUrl
                $wk.Form.Close()
                return
            }
            $wk.Candidate = $k
            $wk.TakeBtn.Enabled = $true
            $wk.Label.Text = 'Found a key, but claude.ai does not accept it yet. If you have not signed in, do it now — I will wait. If you already have, click "Use anyway".'
        } elseif (-not $k) {
            $wk.Label.Text = 'Waiting for you to sign in to Claude in the browser window…'
        }
        $wk.Timer.Start()
    } catch {
        Write-Log "webkey: $_"
        $wk.Timer.Start()
    }
}

function Get-WebKeyAuto([string]$profileName = 'browser') {
    $exe = Find-Browser
    if (-not $exe) { return '__manual__' }
    $bn = [IO.Path]::GetFileNameWithoutExtension($exe)
    $msg = "A separate browser window ($bn) will open claude.ai.`n`nSign in to your Claude account — only the first time, the window remembers it afterwards. As soon as you are signed in, AI Limits takes the session key and closes the window.`n`nThis is a separate browser profile used only by AI Limits: your regular browser, its tabs and passwords are not touched."
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'claude.ai key', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $profileDir = Join-Path $AppDir $profileName
    Close-ProfileBrowser
    $port = Get-FreePort
    $argList = @(('--user-data-dir="' + $profileDir + '"'), "--remote-debugging-port=$port", '--no-first-run', '--no-default-browser-check', '--new-window', 'https://claude.ai/login')
    Start-Process -FilePath $exe -ArgumentList $argList | Out-Null

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'claude.ai key'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'; $dlg.ShowIcon = $false
    $dlg.Font = $DlgFonts.Body
    $dlg.ClientSize = New-Object System.Drawing.Size((S 460), (S 164))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Opening the browser…'
    $lbl.Location = New-Object System.Drawing.Point((S 24), (S 20))
    $lbl.Size = New-Object System.Drawing.Size((S 412), (S 76))
    $dlg.Controls.Add($lbl)

    $take = New-Object AILimitsUI.RoundButton
    $take.Text = 'Use anyway'
    $take.Enabled = $false
    $take.Location = New-Object System.Drawing.Point((S 204), (S 110))
    $take.Size = New-Object System.Drawing.Size((S 120), (S 34))
    $take.Add_Click({
        $script:wk.Key = $script:wk.Candidate
        $u = Get-CdpWsUrl $script:wk.Port
        if ($u) { Close-CdpBrowser $u }
        $script:wk.Form.Close()
    })
    $dlg.Controls.Add($take)

    $cancel = New-Object AILimitsUI.RoundButton
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point((S 332), (S 110))
    $cancel.Size = New-Object System.Drawing.Size((S 104), (S 34))
    $cancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($cancel)
    $dlg.CancelButton = $cancel

    $tmr = New-Object System.Windows.Forms.Timer
    $tmr.Interval = 2000
    $tmr.Add_Tick({ Step-WebKeyWait })

    $script:wk = @{ Port = $port; Key = $null; Candidate = $null; Tried = @{}; Seen = $false; Ticks = 0; Form = $dlg; Label = $lbl; Timer = $tmr; TakeBtn = $take }
    Set-DialogStyle $dlg @($take) @()
    $tmr.Start()
    [void]$dlg.ShowDialog()
    $tmr.Stop(); $tmr.Dispose()
    $dlg.Dispose()
    $key = $script:wk.Key
    $script:wk = $null
    $key
}

function Install-Bridge([string]$sf) {
    $prevF = Join-Path $AppDir 'statusline-prev.txt'
    $cmdLines = @(
        ('$f = ''' + $sf + ''''),
        ('$cmd = ''' + $BridgeCmd + ''''),
        '$ErrorActionPreference = ''Stop''',
        'if (Test-Path $f) { Copy-Item $f ($f + ''.ailimits-backup'') -Force; $s = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null }',
        'if (-not $s) { $s = New-Object PSObject }',
        ('if ($s.statusLine.command -and ($s.statusLine.command -notlike ''*AILimits*'')) { Set-Content -Path ''' + $prevF + ''' -Value $s.statusLine.command -Encoding UTF8 }'),
        '$s | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{ type = ''command''; command = $cmd }) -Force',
        '[IO.File]::WriteAllText($f, ($s | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))',
        'Write-Host ''Done. Open Claude Code and send any message — the limits will appear in AI Limits.'' -ForegroundColor Green'
    )
    $explain = 'Adds a status line to Claude Code settings (an official feature). After each reply Claude Code writes its limits to a file and AI Limits reads them — no server requests. A backup of settings.json is saved first; if you already had a status line, it keeps working.'
    Confirm-AndRun 'Claude Code bridge' $explain ($cmdLines -join "`r`n")
}

# Buttons under an account in Settings: each acts on that account's own folder / browser profile.
function Invoke-AccountAction($it, [string]$what) {
    $dirRaw = [string]$it.configDir
    switch ($what) {
        'BtnWeb' {
            if (-not $it.profile) { Set-DefaultProfile $it $script:edit }
            $k = Get-WebKeyAuto ([string]$it.profile)
            if ($k -and $k -ne '__manual__') { $it['newWebKey'] = $k.Trim() }
        }
        'BtnCli' {
            if ($it.type -eq 'codex') { $d = $AutoDefs['codex']; $envName = 'CODEX_HOME' } else { $d = $AutoDefs['claude-code']; $envName = 'CLAUDE_CONFIG_DIR' }
            $exe = Find-Exe $d.Exe $d.Extra
            if (-not $exe) { [System.Windows.Forms.MessageBox]::Show('The command-line app is not installed yet. Use "Connect automatically…" to install it first.', $AppName) | Out-Null; return }
            $cmd = ''
            if ($dirRaw) { $cmd = '$env:' + $envName + ' = ''' + $dirRaw + '''' + "`r`n" }
            $cmd += "& '" + $exe + "'"
            if ($d.LoginArgs) { $cmd += ' ' + $d.LoginArgs }
            Confirm-AndRun ('Sign in: ' + $it.name) $d.LoginHint $cmd
        }
        'BtnBridge' {
            if ($dirRaw) { $sf = Join-Path ([Environment]::ExpandEnvironmentVariables($dirRaw)) 'settings.json' } else { $sf = Get-ClaudeSettingsPath }
            Install-Bridge $sf
        }
    }
}

function Invoke-AutoAction([string]$type, [string]$action) {
    $d = $AutoDefs[$type]
    switch ($action) {
        'add' { Add-EditProvider $type '' }
        'addenv' { Add-EditProvider $type ([string](Get-AnyEnv $d.Env)) }
        'getkey' {
            Start-Process $d.Url
            $msg = "Opened the $($d.Name) keys page in your browser.`n$($d.KeyHint)`n`nPaste the key here (Ctrl+V). It will be stored encrypted."
            $k = [Microsoft.VisualBasic.Interaction]::InputBox($msg, ('Key — ' + $d.Name), '')
            if ($k -and $k.Trim()) { Add-EditProvider $type $k.Trim() }
        }
        'install' { Confirm-AndRun ('Install: ' + $d.Name) $d.InstallHint $d.Install }
        'webkey' {
            $k = Get-WebKeyAuto
            if ($k -eq '__manual__') {
                Start-Process 'https://claude.ai'
                $msg = "Edge or Chrome was not found, so this has to be done by hand.`n`n1. Press F12 on claude.ai.`n2. Open the Application tab (Storage in Firefox).`n3. Cookies → https://claude.ai`n4. Copy the sessionKey value (sk-ant-sid…).`n`nPaste it here:"
                $k = [Microsoft.VisualBasic.Interaction]::InputBox($msg, 'sessionKey claude.ai', '')
            }
            if ($k -and $k.Trim()) {
                $target = $null
                foreach ($it in $script:edit) { if ($it.type -eq 'claude-code') { $target = $it; break } }
                if (-not $target) { Add-EditProvider 'claude-code' ''; $target = $script:edit[$script:edit.Count - 1] }
                $target['newWebKey'] = $k.Trim()
                Update-SettingsList
            }
        }
        'bridge' { Install-Bridge (Get-ClaudeSettingsPath) }
        'node' {
            Confirm-AndRun 'Install Node.js' 'Codex CLI and Gemini CLI install via npm, which comes with Node.js. This uses winget, the package manager built into Windows. It may ask for confirmation.' 'winget install -e --id OpenJS.NodeJS.LTS'
        }
        'login' {
            $exe = Find-Exe $d.Exe $d.Extra
            if (-not $exe) { return }
            $cmd = "& '" + $exe + "'"
            if ($d.LoginArgs) { $cmd += ' ' + $d.LoginArgs }
            Confirm-AndRun ('Sign in: ' + $d.Name) $d.LoginHint $cmd
        }
    }
}

function Update-AutoRows {
    if (-not $script:auto -or $script:auto.Busy) { return }
    $script:auto.Busy = $true
    try {
        Update-EnvPath
        foreach ($type in $AutoDefs.Keys) {
            $row = $script:auto.Rows[$type]
            $st = Get-AutoStatus $type
            $row.Status.Text = $st.Text
            $row.Status.ForeColor = $st.Color
            if ($st.Button) {
                $row.Button.Text = $st.Button
                $row.Button.Tag = @{ Type = $type; Action = $st.Action }
                $row.Button.Visible = $true
            } else {
                $row.Button.Visible = $false
            }
        }
    } finally { $script:auto.Busy = $false }
}

function Show-AutoConnect {
    $script:auto = @{ Rows = @{}; Busy = $false }
    $wiz = New-Object System.Windows.Forms.Form
    $wiz.Text = 'Connect automatically'
    $wiz.FormBorderStyle = 'FixedDialog'; $wiz.MaximizeBox = $false; $wiz.MinimizeBox = $false
    $wiz.StartPosition = 'CenterParent'; $wiz.ShowIcon = $false
    $wiz.Font = $DlgFonts.Body
    $W = S 640
    $pad = S 28
    $rowH = S 58
    $top = S 112
    $wiz.ClientSize = New-Object System.Drawing.Size($W, ($top + $rowH * $AutoDefs.Count + (S 76)))

    $h1 = New-Object System.Windows.Forms.Label
    $h1.Text = 'Connect automatically'
    $h1.Font = $DlgFonts.H1
    $h1.Location = New-Object System.Drawing.Point($pad, (S 18))
    $h1.Size = New-Object System.Drawing.Size(($W - 2 * $pad), (S 30))
    $wiz.Controls.Add($h1)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Checking what is already on this computer. Subscriptions (Claude, ChatGPT, Gemini) connect through their official terminal apps. No command runs until you click "Run".'
    $intro.ForeColor = $DlgColors.Muted
    $intro.Location = New-Object System.Drawing.Point($pad, (S 54))
    $intro.Size = New-Object System.Drawing.Size(($W - 2 * $pad), (S 44))
    $wiz.Controls.Add($intro)

    $i = 0
    foreach ($type in $AutoDefs.Keys) {
        $y = $top + $rowH * $i
        [void](New-Hairline $wiz $pad $y ($W - 2 * $pad))
        $n = New-Object System.Windows.Forms.Label
        $n.Text = $AutoDefs[$type].Name
        $n.Font = $DlgFonts.Btn
        $n.AutoEllipsis = $true
        $n.Location = New-Object System.Drawing.Point($pad, ($y + (S 9)))
        $n.Size = New-Object System.Drawing.Size(($W - 2 * $pad - (S 170)), (S 20))
        $wiz.Controls.Add($n)

        $st = New-Object System.Windows.Forms.Label
        $st.Font = $DlgFonts.Small
        $st.AutoEllipsis = $true
        $st.Location = New-Object System.Drawing.Point($pad, ($y + (S 30)))
        $st.Size = New-Object System.Drawing.Size(($W - 2 * $pad - (S 170)), (S 18))
        $wiz.Controls.Add($st)

        $b = New-Object AILimitsUI.RoundButton
        $b.Location = New-Object System.Drawing.Point(($W - $pad - (S 150)), ($y + (S 13)))
        $b.Size = New-Object System.Drawing.Size((S 150), (S 32))
        $b.Add_Click({
            $tg = $this.Tag
            if ($tg) { Invoke-AutoAction $tg.Type $tg.Action; Update-AutoRows }
        })
        $wiz.Controls.Add($b)

        $script:auto.Rows[$type] = @{ Status = $st; Button = $b }
        $i++
    }
    $yl = $top + $rowH * $AutoDefs.Count
    [void](New-Hairline $wiz $pad $yl ($W - 2 * $pad))

    $yb = $yl + (S 22)
    $re = New-Object AILimitsUI.RoundButton
    $re.Text = 'Check again'
    $re.Location = New-Object System.Drawing.Point($pad, $yb)
    $re.Size = New-Object System.Drawing.Size((S 120), (S 34))
    $re.Add_Click({ Update-AutoRows })
    $wiz.Controls.Add($re)

    $done = New-Object AILimitsUI.RoundButton
    $done.Text = 'Done'
    $done.Location = New-Object System.Drawing.Point(($W - $pad - (S 100)), $yb)
    $done.Size = New-Object System.Drawing.Size((S 100), (S 34))
    $done.DialogResult = 'OK'
    $wiz.Controls.Add($done)
    $wiz.AcceptButton = $done
    $wiz.CancelButton = $done

    $wiz.Add_Activated({ Update-AutoRows })
    Update-AutoRows
    Set-DialogStyle $wiz @($done) @()
    [void]$wiz.ShowDialog($script:ui.Form)
    $wiz.Dispose()
    $script:auto = $null
}

# ---------- window behaviour: compact mode, hotkey, hiding during games ----------
function Toggle-Compact {
    $script:cfg['compact'] = -not [bool]$script:cfg.compact
    Save-Config
    if ($script:compactItem) { $script:compactItem.Checked = [bool]$script:cfg.compact }
    Update-Visual
    Keep-OnScreen
}

function Register-AppHotKey {
    try {
        $ok = [AILimitsUI.Win]::SetHotKey($form.Handle, [string]$script:cfg.hotkey)
        if (-not $ok) { Write-Log ('hotkey not registered: ' + $script:cfg.hotkey) }
    } catch { Write-Log "hotkey: $_" }
}

function Update-FullscreenState {
    $want = $false
    if ($script:cfg.autoHide -and $form.Visible) {
        try { $want = [AILimitsUI.Win]::FullscreenOnMyMonitor($form.Handle) } catch { $want = $false }
    }
    if ($want -ne $script:suppressed) { $script:suppressed = $want; Update-Visual }
}

# ---------- statistics window: API value from logs, charts, limit history ----------
$StatsInk = @{ Text = (New-Rgb '#121212'); Muted = (New-Rgb '#55554F'); Faint = (New-Rgb '#6B6B66'); Grid = (New-Rgb '#ECEBE7'); Rule = (New-Rgb '#E3E2DD'); Axis = (New-Rgb '#B9B8B2'); Blue = (New-Rgb '#2a78d6'); Orange = (New-Rgb '#eb6834'); Surface = (New-Rgb '#FAFAF8'); Bar = (New-Rgb '#121212') }
$StatsFont = @{
    H1 = New-PxFont $FontNumSemi 22
    H2 = New-PxFont 'Segoe UI Semibold' 12
    Kpi = New-PxFont $FontNum 30
    Caps = New-PxFont 'Segoe UI Semibold' 10
    Small = New-PxFont 'Segoe UI' 11
    Body = New-PxFont 'Segoe UI' 12
    Mono = New-PxFont $FontMono 12
}

function SDraw($g, [string]$s, $font, $color, [single]$x, [single]$y, [string]$align = 'left') {
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $sz = $g.MeasureString($s, $font, [System.Drawing.PointF]::new(0, 0), $TypoFormat)
    if ($align -eq 'right') { $x -= $sz.Width } elseif ($align -eq 'center') { $x -= $sz.Width / 2 }
    $br = New-Object System.Drawing.SolidBrush($color)
    $g.DrawString($s, $font, $br, $x, $y, $TypoFormat)
    $br.Dispose()
    $sz
}

function Format-Money([double]$v) {
    if ($v -ge 100) { return ('${0:N0}' -f $v) }
    if ($v -ge 1) { return ('${0:N2}' -f $v) }
    if ($v -gt 0) { return ('${0:N3}' -f $v) }
    '$0'
}

function Get-NiceMax([double]$v) {
    if ($v -le 0) { return 1.0 }
    $e = [math]::Pow(10, [math]::Floor([math]::Log10($v)))
    foreach ($m in 1, 2, 2.5, 5, 10) { if ($m * $e -ge $v) { return $m * $e } }
    10 * $e
}

# Single-series column chart: one hue, 4px rounded data end on the baseline side, recessive grid, hover text per column.
function Draw-Columns($g, [single]$x, [single]$y, [single]$w, [single]$h, [double[]]$vals, [string[]]$labels, [string[]]$tips) {
    $axisW = S 46
    $px = $x + $axisW; $pw = $w - $axisW; $ph = $h - (S 20)
    $max = Get-NiceMax (($vals | Measure-Object -Maximum).Maximum)
    $pen = New-Object System.Drawing.Pen($StatsInk.Grid, 1)
    foreach ($f in 0, 0.5, 1) {
        $gy = [math]::Round($y + $ph - $ph * $f) + 0.5
        $g.DrawLine($pen, $px, $gy, $x + $w, $gy)
        [void](SDraw $g (Format-Money ($max * $f)) $StatsFont.Small $StatsInk.Muted ($px - (S 6)) ($gy - (S 8)) 'right')
    }
    $pen.Dispose()
    $n = $vals.Count
    $slot = $pw / $n
    $bw = [math]::Max((S 3), $slot - (S 2) - [math]::Min((S 10), $slot * 0.3))
    $br = New-Object System.Drawing.SolidBrush($StatsInk.Blue)
    $old = $g.Clip
    $g.SetClip((New-Object System.Drawing.RectangleF($px, ($y - 2), $pw, ($ph + 2))))
    for ($i = 0; $i -lt $n; $i++) {
        $bx = $px + $i * $slot + ($slot - $bw) / 2
        $bh = [single]($ph * $vals[$i] / $max)
        $script:statsHits += @{ Rect = (New-Object System.Drawing.RectangleF(($px + $i * $slot), $y, $slot, $ph)); Text = $tips[$i] }
        if ($bh -le 0) { continue }
        $r = [math]::Min((S 4), $bw / 2)
        $path = New-RoundPath $bx ($y + $ph - $bh) $bw ($bh + $r) $r
        $g.FillPath($br, $path)
        $path.Dispose()
    }
    $g.Clip = $old
    $br.Dispose()
    $ap = New-Object System.Drawing.Pen($StatsInk.Axis, 1)
    $ay = [math]::Round($y + $ph) + 0.5
    $g.DrawLine($ap, $px, $ay, $x + $w, $ay); $ap.Dispose()
    for ($i = 0; $i -lt $n; $i++) {
        if (-not $labels[$i]) { continue }
        [void](SDraw $g $labels[$i] $StatsFont.Small $StatsInk.Muted ($px + $i * $slot + $slot / 2) ($y + $ph + (S 5)) 'center')
    }
}

# Two-series line chart on one 0–100% axis, 2px lines, legend plus direct labels at the line ends.
function Draw-LimitLines($g, [single]$x, [single]$y, [single]$w, [single]$h, $series, [int64]$t0, [int64]$t1) {
    $axisW = S 46
    $px = $x + $axisW; $pw = $w - $axisW - (S 90); $ph = $h - (S 20)
    $pen = New-Object System.Drawing.Pen($StatsInk.Grid, 1)
    foreach ($f in 0, 0.5, 1) {
        $gy = [math]::Round($y + $ph - $ph * $f) + 0.5
        $g.DrawLine($pen, $px, $gy, $px + $pw, $gy)
        [void](SDraw $g ('{0}%' -f [int](100 * $f)) $StatsFont.Small $StatsInk.Muted ($px - (S 6)) ($gy - (S 8)) 'right')
    }
    $pen.Dispose()
    for ($d = 0; $d -le 7; $d++) {
        $tt = $t1 - (7 - $d) * 86400
        $lx = $px + $pw * ($tt - $t0) / ($t1 - $t0)
        $lbl = [DateTimeOffset]::FromUnixTimeSeconds($tt).ToLocalTime().ToString('ddd')
        if ($d -lt 7) { [void](SDraw $g $lbl $StatsFont.Small $StatsInk.Muted $lx ($y + $ph + (S 5)) 'center') }
    }
    $g.SmoothingMode = 'AntiAlias'
    foreach ($s in $series) {
        $pts = @($s.Pts)
        if ($pts.Count -lt 1) { continue }
        $lp = New-Object System.Drawing.Pen($s.Color, (S 2))
        $lp.LineJoin = 'Round'
        $arr = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        foreach ($pt in $pts) { $arr.Add([System.Drawing.PointF]::new(($px + $pw * ($pt[0] - $t0) / ($t1 - $t0)), ($y + $ph - $ph * [math]::Min(100, $pt[1]) / 100))) }
        if ($arr.Count -ge 2) { $g.DrawLines($lp, $arr.ToArray()) }
        $lastP = $arr[$arr.Count - 1]
        $dot = New-Object System.Drawing.SolidBrush($s.Color)
        $g.FillEllipse($dot, $lastP.X - (S 4), $lastP.Y - (S 4), (S 8), (S 8))
        $dot.Dispose(); $lp.Dispose()
        [void](SDraw $g ('{0} {1}%' -f $s.Name, [int][math]::Round($pts[-1][1])) $StatsFont.Small $StatsInk.Text ($lastP.X + (S 8)) ($lastP.Y - (S 8)))
    }
}

function Draw-TopList($g, [single]$x, [single]$y, [single]$w, $items, [int]$rows) {
    $list = @($items | Select-Object -First $rows)
    if (-not $list) { [void](SDraw $g 'No data yet' $StatsFont.Body $StatsInk.Muted $x $y); return }
    $max = [math]::Max(0.0001, [double]$list[0].Value)
    $br = New-Object System.Drawing.SolidBrush($StatsInk.Bar)
    $tr = New-Object System.Drawing.SolidBrush($StatsInk.Grid)
    $rp = New-Object System.Drawing.Pen($StatsInk.Grid, 1)
    $nameW = [math]::Min((S 150), $w * 0.42); $valW = S 70
    $bx = $x + $nameW + (S 10); $bw = $w - $nameW - $valW - (S 20)
    foreach ($it in $list) {
        $name = [string]$it.Key
        if ($name.Length -gt 22) { $name = $name.Substring(0, 21) + '…' }
        [void](SDraw $g $name $StatsFont.Body $StatsInk.Text $x ($y + (S 5)))
        $g.FillRectangle($tr, $bx, $y + (S 11), $bw, (S 6))
        $g.FillRectangle($br, $bx, $y + (S 11), [single][math]::Max((S 2), $bw * [double]$it.Value / $max), (S 6))
        [void](SDraw $g (Format-Money ([double]$it.Value)) $StatsFont.Mono $StatsInk.Text ($x + $w) ($y + (S 5)) 'right')
        $y += S 28
        $ly = [math]::Round($y) - 0.5
        $g.DrawLine($rp, $x, $ly, $x + $w, $ly)
    }
    $br.Dispose(); $tr.Dispose(); $rp.Dispose()
}

function Get-StatsPlan($prov) {
    foreach ($r in @($script:results)) {
        if ($r.Id -ne $prov.id) { continue }
        foreach ($ln in @($r.Lines)) { if ([string]$ln.Label -match '^vs \$([\d,\.]+) plan$') { return [double]($matches[1] -replace ',', '') } }
    }
    0.0
}

function Render-Stats($prov) {
    $script:statsHits = @()
    $W = S 720
    $H = S 900
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($StatsInk.Surface)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $pad = S 24; $cw = $W - 2 * $pad
    $sum = $null
    try { $sum = [AILimitsUI.UsageLog]::Summarize($prov.id, (Join-Path $AppDir 'usage'), $PricingPath, [DateTime]::Now) } catch { Write-Log "stats: $_" }
    $y = S 18
    $hsz = SDraw $g ([string]$prov.name) $StatsFont.H1 $StatsInk.Text $pad $y
    [void](SDraw $g 'API value from Claude Code / Codex logs' $StatsFont.Small $StatsInk.Faint ($pad + $hsz.Width + (S 14)) ($y + (S 9)))
    $y += S 44

    # headline numbers
    $plan = Get-StatsPlan $prov
    $month = 0.0; $today = 0.0; $req = 0.0; $tok = 0.0
    if ($sum) { $month = $sum.MonthCost; $today = $sum.TodayCost; $req = $sum.MonthRequests; $tok = $sum.MonthTokens }
    $tiles = @(
        @('API value this month', (Format-Money $month)),
        @('Today', (Format-Money $today)),
        @('Compared with the plan', $(if ($plan -gt 0) { '×{0:N1}' -f ($month / $plan) } else { '—' }))
    )
    $tw = $cw / 3
    $rule = New-Object System.Drawing.Pen($StatsInk.Rule, 1)
    $g.DrawLine($rule, $pad, [single]([math]::Round($y) + 0.5), $pad + $cw, [single]([math]::Round($y) + 0.5))
    $g.DrawLine($rule, $pad, [single]([math]::Round($y + (S 80)) + 0.5), $pad + $cw, [single]([math]::Round($y + (S 80)) + 0.5))
    for ($i = 0; $i -lt 3; $i++) {
        $tx = $pad + $i * $tw
        if ($i -gt 0) { $g.DrawLine($rule, [single]([math]::Round($tx) + 0.5), $y, [single]([math]::Round($tx) + 0.5), $y + (S 80)); $tx += S 20 }
        [void](SDraw $g $tiles[$i][0].ToUpperInvariant() $StatsFont.Caps $StatsInk.Faint $tx ($y + (S 14)))
        [void](SDraw $g $tiles[$i][1] $StatsFont.Kpi $StatsInk.Text $tx ($y + (S 32)))
    }
    $rule.Dispose()
    $y += S 92
    $sub = '{0:N0} requests · {1:N1}M tokens this month' -f $req, ($tok / 1e6)
    if ($plan -gt 0) { $sub += (' · plan ${0:N0}/month' -f $plan) }
    $sub += ' · prices from pricing.tsv'
    [void](SDraw $g $sub $StatsFont.Small $StatsInk.Muted $pad $y)
    $y += S 30

    # today by hour
    [void](SDraw $g 'Today by hour (API value)' $StatsFont.H2 $StatsInk.Text $pad $y)
    $y += S 26
    $hv = New-Object double[] 24; $hl = New-Object string[] 24; $ht = New-Object string[] 24
    for ($i = 0; $i -lt 24; $i++) {
        if ($sum) { $hv[$i] = $sum.Hours[$i] }
        if ($i % 3 -eq 0) { $hl[$i] = '{0:00}' -f $i }
        $ht[$i] = '{0:00}:00–{1:00}:00 · {2}' -f $i, (($i + 1) % 24), (Format-Money $hv[$i])
    }
    Draw-Columns $g $pad $y $cw (S 130) $hv $hl $ht
    $y += S 150

    # last 14 days
    [void](SDraw $g 'Last 14 days (API value)' $StatsFont.H2 $StatsInk.Text $pad $y)
    $y += S 26
    $dv = New-Object double[] 14; $dl = New-Object string[] 14; $dt = New-Object string[] 14
    for ($i = 0; $i -lt 14; $i++) {
        $day = [DateTime]::Today.AddDays($i - 13)
        if ($sum -and $i -lt $sum.Days.Count) { $dv[$i] = $sum.Days[$i].Value }
        $dl[$i] = $day.ToString('dd.MM')
        if ($i % 2 -eq 1 -and $i -ne 13) { $dl[$i] = '' }
        $dt[$i] = $day.ToString('ddd dd.MM') + ' · ' + (Format-Money $dv[$i])
    }
    Draw-Columns $g $pad $y $cw (S 130) $dv $dl $dt
    $y += S 150

    # limit history
    [void](SDraw $g 'Limits, last 7 days' $StatsFont.H2 $StatsInk.Text $pad $y)
    $y += S 26
    $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $t0 = $t1 - 7 * 86400
    $hf = Join-Path $AppDir ('history-' + $prov.id + '.tsv')
    $byLabel = [ordered]@{}
    if (Test-Path $hf) {
        foreach ($ln in Get-Content $hf) {
            $a = $ln.Split("`t")
            if ($a.Count -lt 3) { continue }
            $tt = [int64]$a[0]
            if ($tt -lt $t0) { continue }
            if (-not $byLabel.Contains($a[1])) { $byLabel[$a[1]] = New-Object System.Collections.ArrayList }
            [void]$byLabel[$a[1]].Add(@($tt, [double]::Parse($a[2], [Globalization.CultureInfo]::InvariantCulture)))
        }
    }
    $series = @(); $colors = @($StatsInk.Blue, $StatsInk.Orange); $ci = 0
    foreach ($k in $byLabel.Keys) {
        if ($ci -ge 2) { break }
        $series += @{ Name = [string]$k; Color = $colors[$ci]; Pts = @($byLabel[$k]) }
        $ci++
    }
    if ($series.Count) {
        $lx = $pad
        foreach ($s in $series) {
            $db = New-Object System.Drawing.SolidBrush($s.Color)
            $g.FillRectangle($db, $lx, $y + (S 7), (S 14), (S 2)); $db.Dispose()
            $sz = SDraw $g $s.Name $StatsFont.Small $StatsInk.Muted ($lx + (S 20)) $y
            $lx += $sz.Width + (S 28)
        }
        $y += S 22
        Draw-LimitLines $g $pad $y $cw (S 150) $series $t0 $t1
    } else {
        [void](SDraw $g 'History starts filling in from now on — the widget records every reading.' $StatsFont.Body $StatsInk.Muted $pad $y)
    }
    $y += S 176

    # top lists
    $half = ($cw - (S 24)) / 2
    [void](SDraw $g 'Top models this month' $StatsFont.H2 $StatsInk.Text $pad $y)
    [void](SDraw $g 'Top projects this month' $StatsFont.H2 $StatsInk.Text ($pad + $half + (S 24)) $y)
    $y += S 28
    $models = @(); $projects = @()
    if ($sum) { $models = @($sum.Models); $projects = @($sum.Projects) }
    Draw-TopList $g $pad $y $half $models 5
    Draw-TopList $g ($pad + $half + (S 24)) $y $half $projects 5
    $y += S 172

    $g.Dispose()
    if ($y -lt $H) {
        $crop = $bmp.Clone((New-Object System.Drawing.Rectangle(0, 0, $W, [int]$y)), $bmp.PixelFormat)
        $bmp.Dispose()
        return $crop
    }
    $bmp
}

function Show-Stats {
    $accts = @($script:cfg.providers | Where-Object { $_.type -in 'claude-code', 'codex' })
    if (-not $accts) { [System.Windows.Forms.MessageBox]::Show('Statistics need a Claude or ChatGPT (Codex) account in Settings.', $AppName) | Out-Null; return }
    if ($script:statsForm -and -not $script:statsForm.IsDisposed) { $script:statsForm.Activate(); return }

    $sf = New-Object System.Windows.Forms.Form
    $sf.Text = 'AI Limits — Statistics'
    $sf.StartPosition = 'CenterScreen'
    $sf.ShowIcon = $false
    $sf.ClientSize = New-Object System.Drawing.Size((S 760), (S 720))
    $sf.MinimumSize = New-Object System.Drawing.Size((S 500), (S 400))

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'; $top.Height = S 52
    $sf.Controls.Add($top)

    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'
    $cb.Location = New-Object System.Drawing.Point((S 24), (S 15))
    $cb.Size = New-Object System.Drawing.Size((S 260), (S 26))
    foreach ($a in $accts) { [void]$cb.Items.Add([string]$a.name) }
    $top.Controls.Add($cb)

    $rb = New-Object AILimitsUI.RoundButton
    $rb.Text = 'Refresh'
    $rb.Location = New-Object System.Drawing.Point((S 296), (S 12))
    $rb.Size = New-Object System.Drawing.Size((S 96), (S 30))
    $top.Controls.Add($rb)

    $pricing = New-Object AILimitsUI.RoundButton
    $pricing.Text = 'Edit prices…'
    $pricing.Location = New-Object System.Drawing.Point((S 400), (S 12))
    $pricing.Size = New-Object System.Drawing.Size((S 116), (S 30))
    $pricing.Add_Click({ Start-Process notepad.exe -ArgumentList ('"' + $PricingPath + '"') })
    $top.Controls.Add($pricing)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.AutoScroll = $true
    $sf.Controls.Add($panel)
    $panel.BringToFront()

    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.SizeMode = 'AutoSize'
    $pb.Location = New-Object System.Drawing.Point(0, 0)
    $panel.Controls.Add($pb)

    $tip = New-Object System.Windows.Forms.ToolTip
    $script:statsUi = @{ Form = $sf; Combo = $cb; Pic = $pb; Tip = $tip; Accts = $accts; LastTip = '' }
    $redraw = {
        $u = $script:statsUi
        $i = [math]::Max(0, $u.Combo.SelectedIndex)
        $old = $u.Pic.Image
        $u.Pic.Image = Render-Stats $u.Accts[$i]
        if ($old) { $old.Dispose() }
    }
    $script:statsRedraw = $redraw
    $cb.Add_SelectedIndexChanged({ & $script:statsRedraw })
    $rb.Add_Click({ Start-Refresh -Force; & $script:statsRedraw })
    $pb.Add_MouseMove({
        $txt = ''
        foreach ($h in @($script:statsHits)) { if ($h.Rect.Contains([single]$_.X, [single]$_.Y)) { $txt = [string]$h.Text; break } }
        if ($txt -ne $script:statsUi.LastTip) { $script:statsUi.LastTip = $txt; $script:statsUi.Tip.SetToolTip($script:statsUi.Pic, $txt) }
    })
    Set-DialogStyle $sf @() @()
    $top.BackColor = $DlgColors.Bg
    $panel.BackColor = $StatsInk.Surface
    [void](New-Hairline $top 0 ($top.Height - 1) (S 4000))
    $cb.SelectedIndex = 0
    $sf.Add_FormClosed({ if ($script:statsUi.Pic.Image) { $script:statsUi.Pic.Image.Dispose() }; $script:statsForm = $null })
    $script:statsForm = $sf
    $sf.Show()
}

# ---------- tray and menu ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
Set-MenuStyle $menu
[void]$menu.Items.Add('Show / hide', $null, { Toggle-Window })
[void]$menu.Items.Add('Refresh now', $null, { Start-Refresh -Force })
[void]$menu.Items.Add('Statistics…', $null, { Show-Stats })
$script:compactItem = New-Object System.Windows.Forms.ToolStripMenuItem('Compact mode')
$script:compactItem.Checked = [bool]$script:cfg.compact
$script:compactItem.Add_Click({ Toggle-Compact })
[void]$menu.Items.Add($script:compactItem)
[void]$menu.Items.Add('Settings…', $null, { Show-Settings })
$textMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Text rendering')
$script:textItems = @{}
foreach ($tm in @(@('crisp', 'Crisp (recommended)'), @('smooth', 'Smooth'), @('cleartype', 'ClearType'))) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($tm[1])
    $mi.Tag = $tm[0]
    $mi.Checked = ((Get-TextMode) -eq $tm[0])
    $mi.Add_Click({
        $script:cfg['textMode'] = [string]$this.Tag
        Save-Config
        foreach ($k in $script:textItems.Keys) { $script:textItems[$k].Checked = ($k -eq $script:cfg.textMode) }
        Update-Visual
    })
    $script:textItems[$tm[0]] = $mi
    [void]$textMenu.DropDownItems.Add($mi)
}
[void]$menu.Items.Add($textMenu)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Exit', $null, { Exit-App })

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.ContextMenuStrip = $menu
$notify.Text = $AppName
$notify.Add_MouseClick({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Window } })
Set-TrayIcon 'AI' $Glass.Ink ([System.Drawing.Color]::White)
$notify.Visible = $true

$form.ContextMenuStrip = $menu

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = [math]::Max(1, [int]$script:cfg.interval) * 60000
$refreshTimer.Add_Tick({ Start-Refresh })

$glassTimer = New-Object System.Windows.Forms.Timer
$glassTimer.Interval = 3000
$glassTimer.Add_Tick({ if ($form.Visible -and -not $script:pressed -and -not $script:suppressed) { Update-Visual } })

$fsTimer = New-Object System.Windows.Forms.Timer
$fsTimer.Interval = 1000
$fsTimer.Add_Tick({ Update-FullscreenState })

$form.Add_HotKey({ Toggle-Window })

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 250
$pollTimer.Add_Tick({ Check-Job })

$form.Add_FormClosing({ if (-not $script:exiting) { $_.Cancel = $true; $form.Hide() } })
$form.Add_Shown({ Start-Refresh; $refreshTimer.Start(); $pollTimer.Start(); $glassTimer.Start(); $fsTimer.Start() })

if (-not $script:firstPlace) { $form.Location = New-Object System.Drawing.Point([int]$script:cfg.x, [int]$script:cfg.y) }
Render-Results $null
Register-AppHotKey

try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    Write-Log "fatal: $_"
    [System.Windows.Forms.MessageBox]::Show("AI Limits crashed: $_`nDetails: $LogPath", $AppName) | Out-Null
} finally {
    $notify.Visible = $false
    $notify.Dispose()
    if ($script:hIcon -ne [IntPtr]::Zero) { [void][AILimits.Native]::DestroyIcon($script:hIcon) }
    try { $script:mutex.ReleaseMutex() } catch {}
}
