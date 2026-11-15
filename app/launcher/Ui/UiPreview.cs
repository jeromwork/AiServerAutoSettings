using System.Drawing;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Deliberately not wired to EntryPoint. Open this form from a Windows UI harness.
    internal static class UiPreview
    {
        internal static Form Create()
        {
            var form = new Form {
                Text = "RemoteAgents — витрина контролов", Font = Theme.Body,
                AutoScaleDimensions = new SizeF(7F, 15F), AutoScaleMode = AutoScaleMode.Font,
                ClientSize = new Size(420, 600), MinimumSize = new Size(340, 420),
                BackColor = Theme.Window, ForeColor = Theme.Text, StartPosition = FormStartPosition.CenterScreen
            };
            var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(16) };
            var stack = Stack();
            form.Controls.Add(scroll);
            scroll.Controls.Add(stack);
            Add(stack, new Label { Text = "Главное окно", Font = Theme.Big, AutoSize = true });

            var switches = Stack();
            Add(switches, new Label { Text = "VPN", Font = Theme.Title, AutoSize = true });
            AddSwitch(switches, "Защита выключена", false, false, true);
            AddSwitch(switches, "Защита включена", true, false, true);
            AddSwitch(switches, "Включается…", false, true, true);
            AddSwitch(switches, "Выключается…", true, true, true);
            AddSwitch(switches, "Недоступен · выключен", false, false, false);
            AddSwitch(switches, "Недоступен · включён", true, false, false);
            Add(stack, Card(switches));

            var longText = Stack();
            Add(longText, new Label { Text = "Диск", Font = Theme.Title, AutoSize = true });
            Add(longText, new Label { AutoSize = true, Text = "Все выбранные папки синхронизированы. " +
                "Большая папка с документами и фотографиями семьи хранится только на сервере; " +
                "её можно скачать на компьютер из меню Проводника.", ForeColor = Theme.Muted });
            Add(longText, new Button { Text = "Открыть Диск", AutoSize = true, UseVisualStyleBackColor = true });
            Add(stack, Card(longText));

            var expander = new Expander { Title = "Дополнительно", Dock = DockStyle.Top };
            var expandedContent = Stack();
            Add(expandedContent, new Label { AutoSize = true, Text = "Здесь размещаются редактор конфига и диагностика. " +
                "Заголовок открывается мышью, клавишами Enter и пробелом.", ForeColor = Theme.Muted });
            expander.Body.Controls.Add(expandedContent);

            AddBanner(stack, Tone.Off, "Защита выключена. Включите VPN, когда он понадобится.", "Включить", expander);
            AddBanner(stack, Tone.Ok, "Всё работает. Файлы синхронизированы, помощник подключён.", "", expander);
            AddBanner(stack, Tone.Warning, "Основной путь временно недоступен. Пробуем запасной путь; " +
                "подключение может занять немного больше времени.", "Повторить", expander);
            AddBanner(stack, Tone.Error, "Не удаётся связаться с сервером. Проверьте подключение к интернету " +
                "и попробуйте ещё раз. Если это не поможет, откройте подробности.", "Повторить", expander);
            Add(stack, expander);

            var openExpander = new Expander { Title = "Открытый раздел", Expanded = true, Dock = DockStyle.Top };
            var openContent = Stack();
            Add(openContent, new Label { AutoSize = true, Text = "Раздел сразу развёрнут. При сворачивании высота " +
                "освобождается для остальных карточек.", ForeColor = Theme.Muted });
            openExpander.Body.Controls.Add(openContent);
            Add(stack, openExpander);
            WindowChrome.Apply(form);
            return form;
        }

        static TableLayoutPanel Stack()
        {
            var stack = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, RowCount = 0,
                Margin = Padding.Empty, Padding = Padding.Empty };
            stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            stack.Layout += delegate {
                foreach (Control child in stack.Controls) {
                    var label = child as Label;
                    if (label == null) continue;
                    int width = System.Math.Max(1, stack.ClientSize.Width - stack.Padding.Horizontal - label.Margin.Horizontal);
                    if (label.MaximumSize.Width != width) label.MaximumSize = new Size(width, 0);
                }
            };
            return stack;
        }

        static void Add(TableLayoutPanel stack, Control control)
        {
            control.Dock = DockStyle.Top;
            control.Margin = new Padding(0, 0, 0, 10);
            stack.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            stack.Controls.Add(control, 0, stack.RowCount++);
        }

        static CardPanel Card(Control content)
        {
            var card = new CardPanel { Dock = DockStyle.Top };
            card.Controls.Add(content);
            return card;
        }

        static void AddSwitch(TableLayoutPanel stack, string text, bool on, bool busy, bool enabled)
        {
            var row = new TableLayoutPanel { ColumnCount = 2, RowCount = 1, AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Top, Margin = Padding.Empty };
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var label = new Label { Text = text, AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = Theme.Muted };
            var toggle = new ToggleSwitch { Checked = on, Busy = busy, Enabled = enabled, Text = text, Anchor = AnchorStyles.Right };
            // The preview is its own owner: real windows set Checked from the measured status instead.
            toggle.Toggled += delegate { toggle.Checked = !toggle.Checked; };
            row.Controls.Add(label, 0, 0);
            row.Controls.Add(toggle, 1, 0);
            row.Layout += delegate {
                int width = System.Math.Max(1, row.ClientSize.Width - toggle.Width - toggle.Margin.Horizontal - label.Margin.Horizontal);
                if (label.MaximumSize.Width != width) label.MaximumSize = new Size(width, 0);
            };
            Add(stack, row);
        }

        static void AddBanner(TableLayoutPanel stack, Tone tone, string text, string actionText, Expander details)
        {
            var banner = new InfoBar { Dock = DockStyle.Top };
            banner.ShowMessage(tone, text, actionText);
            banner.ActionClicked += delegate { banner.ShowMessage(tone, "Действие запрошено. " + text, actionText); };
            banner.DetailsClicked += delegate {
                details.Expanded = true;
                details.SelectNextControl(null, true, true, true, false);
                for (Control parent = details.Parent; parent != null; parent = parent.Parent) {
                    var scroll = parent as ScrollableControl;
                    if (scroll != null && scroll.AutoScroll) { scroll.ScrollControlIntoView(details); break; }
                }
            };
            Add(stack, banner);
        }
    }
}
