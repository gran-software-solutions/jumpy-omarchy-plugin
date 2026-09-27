<div align="center">

# Jumpy

**Alt+Tab for Omarchy, built for speed.**
Tap to flip back. Hold to see every window. Type to find one.

<br>

<img src="preview.png" alt="Jumpy's window list: one row per window, most recent first, with the app icon and name, the title, and the workspace number" width="100%">

<sub>Follows the active Omarchy theme and font.</sub>

</div>

<br>

## Install

```bash
omarchy plugin add https://github.com/gran-software-solutions/jumpy-omarchy-plugin.git --enable --yes
```

Add one line to `~/.config/hypr/bindings.lua`, then run `hyprctl reload`:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/de.gransoftware.jumpy/jumpy.lua")
```

It takes over Omarchy's `Alt+Tab`. Remove the line and reload to get the default back.
Requires Hyprland 0.56+ with a Lua config.

## Keys

Hold `Alt` throughout. Releasing it switches.

| | |
| --- | --- |
| `Tab` · `Shift+Tab` | Next · previous |
| letters | Fuzzy filter: `br` → Brave, `vsc` → Visual Studio Code |
| `Ctrl+J` · `Ctrl+K` | Down · up |
| `Ctrl+W` | Close the selected window |
| `Ctrl+U` · `Backspace` | Clear the filter · delete a letter |
| `` ` `` | Only this app's windows |
| `Esc` | Cancel |

A quick tap flips to your last window without drawing anything.

<details>
<summary><b>How it works</b></summary>
<br>

`jumpy.lua` runs inside Hyprland and owns the keys, the window snapshot, the
filter and the cursor. `Jumpy.qml` runs inside `omarchy-shell` and only draws,
driven by `omarchy-shell jumpy show|hide`.

While the list is up, a `jumpy` submap swallows every other key, so nothing
leaks into the window behind it. Three things end the submap: the Alt release,
a poll that notices Alt is up, and a 20-second timeout, so it can never trap
the keyboard.

</details>

<br>

<sub>Written entirely by [Claude](https://claude.com/claude-code). It runs unsandboxed, so read the source before you enable it. &nbsp;·&nbsp; [MIT](LICENSE) © Gran Software Solutions</sub>
