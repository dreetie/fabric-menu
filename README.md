# fabric-menu

A keyboard-driven [rofi](https://github.com/davatorium/rofi) / [wofi](https://hg.sr.ht/~scoopta/wofi)
menu for [Fabric](https://github.com/danielmiessler/fabric). Select (or copy) some text or a URL,
press your shortcut, pick a pattern, and the result lands in your clipboard.

## Features

- Works on text, web URLs (`fabric -u`) and YouTube links (`fabric -y`)
- Pattern picker with one unified favorites list (⭐): single patterns, pattern chains or full command templates
- Chain patterns together (pipe one pattern's output into the next)
- Options menu: language, context, model, prompt strategy, extra flags, save to a Markdown file
- Optional result preview window and desktop notifications
- **Email Flow**: turns a pasted email thread into an interactive mind map in your browser (try it with the fictional thread in [`examples/email-thread-sample.txt`](examples/email-thread-sample.txt): copy its text, open the menu, choose "Email Flow")
- Quick Run mode, `--dry-run`, copy-the-command and error screen with copy buttons

## Requirements

`fabric` (or `fabric-ai`), `rofi` (or `wofi`), `wl-clipboard` (Wayland) or `xclip` (X11),
`libnotify` (optional notifications). For `CAPTURE_MODE=copy-keystroke`: `wtype` or `ydotool`.

## Install

```bash
git clone https://github.com/dreetie/fabric-menu.git
mkdir -p ~/.local/bin
ln -s "$PWD/fabric-menu/fabric-menu" ~/.local/bin/fabric-menu   # a link keeps patterns/ and templates/ findable
```

Then bind `fabric-menu` to a shortcut (KDE: System Settings → Shortcuts; Hyprland:
`bind = SUPER, F, exec, fabric-menu`). The first run creates `~/.config/fabric-menu/`.

## Configuration

Open the menu and choose **⚙️ Settings...**: every option can be changed there. The settings live in
`~/.config/fabric-menu/config.conf`, a plain `KEY=value` text file (it is read as data, never run as a script),
so you can also edit it by hand. An old `config.sh` is converted automatically (kept as `config.sh.migrated`).

| Option | Meaning |
|---|---|
| `CAPTURE_MODE` | `highlight` (highlighted text, else clipboard), `clipboard` (only what is copied), `copy-keystroke` (presses Ctrl+C for you) |
| `CUSTOM_COMMANDS` | Shows the "Custom Command" menu item (off by default, see the warning below) |
| `STRIP_CODE_FENCE` | Remove a stray ```` ```markdown ```` fence the model wraps around its answer |
| `MENU_TOOL` | `auto`, `rofi`, `wofi` |
| `QUICK_RUN` | Run immediately after choosing a pattern |
| `DEFAULT_LANG` / `DEFAULT_MODEL` / `DEFAULT_STRATEGY` | Defaults passed to Fabric |

## Hyprland notes

Highlighted text ("primary selection") is not reliably available on every Hyprland setup, so
the menu may find nothing unless you copied first. Set `CAPTURE_MODE=copy-keystroke` (needs `wtype`)
to have the menu press Ctrl+C for you, or `clipboard` to always use what is already copied.

## Warning: custom commands

The optional "Custom Command" entry (and favorites saved from it) runs whatever shell command you type,
with your own permissions. A wrong command such as `rm` can delete files or damage your system. It is off
by default; enable it in Settings only if you are comfortable with that, and only use favorites files you trust.

## Privacy

Text you send is processed by whichever AI provider your Fabric is configured for. The Email
Flow map page loads its JavaScript libraries from a public CDN (jsdelivr).

## License

[MIT](LICENSE). Fabric itself is a separate project by Daniel Miessler with its own license.
