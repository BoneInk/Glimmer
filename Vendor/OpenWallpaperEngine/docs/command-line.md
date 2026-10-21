# Command line

Open Wallpaper Engine takes Wallpaper Engine's command-line commands
([`-control`](https://help.wallpaperengine.io/en/functionality/cli.html)), so scripts, launchers
and automation tools written for Wallpaper Engine work with small changes. A command goes to the
app that is running; start Open Wallpaper Engine first, as Wallpaper Engine needs too.

Run the app's executable with `--control` and the command:

```sh
OWE="/Applications/Open Wallpaper Engine.app/Contents/MacOS/Open Wallpaper Engine"
"$OWE" --control pause
"$OWE" --control open-wallpaper --file ~/Wallpapers/Forest/project.json --monitor 1
```

Wallpaper Engine's own spelling works as well, so a command copied from a Windows script runs
unchanged apart from the executable:

```sh
"$OWE" -control openWallpaper -file "/Users/me/Wallpapers/Forest/project.json" -playInWindow "Left" -width 800 -height 600
```

Commands and option names ignore case, dashes and underscores: `open-wallpaper`, `openWallpaper`
and `OPENWALLPAPER` are the same, and so are `--play-in-window` and `-playInWindow`. Put values
with spaces in quotes.

The command prints its answer (only `get-wallpaper` has one) and exits with status 0. When the
command fails it prints why on standard error and exits with 1; an unknown command or option
exits with 64 and the usage, and 69 when the app isn't running or doesn't answer within 10
seconds.

## Commands

| Command | Options | What it does |
| --- | --- | --- |
| `pause` | | Pauses every wallpaper (Pause in the menu bar menu). |
| `stop` | | Stops every wallpaper: unloads them and shows the desktop picture (Stop Wallpapers). |
| `play` | | Plays again after `pause` or `stop`. |
| `mute` / `unmute` | | Mutes or unmutes every wallpaper. |
| `open-wallpaper` | `--file` (required), `--monitor`, `--location`, `--preset`, `--play-in-window`, `--width`, `--height`, `--x`, `--y`, `--borderless`, `--activate` | Sets a wallpaper on a display (the main display when none is given), or plays it in a window. |
| `next-wallpaper` | `--monitor`, `--location` | Next Wallpaper on that display, or on every display. |
| `close-wallpaper` | `--monitor`, `--location` | Closes the Play in Window window of that name, or turns the display's wallpaper off (the Displays sheet's switch). Without either, closes every window and turns every display's wallpaper off. |
| `open-playlist` | `--playlist` (required), `--monitor`, `--location` | Starts the playlist of that name, on that display or on the playlist's own displays. |
| `open-profile` | `--profile` (required) | Loads the display profile of that name. |
| `apply-properties` | `--properties` (required), `--monitor`, `--location` | Changes the user properties of the wallpaper on that display or in that window (the main display's when neither is given). |
| `hide-icons` / `show-icons` | | Shows the wallpaper above the desktop icons, or below them again (the Hide desktop icons hotkey). |
| `get-wallpaper` | `--monitor`, `--location` | Prints the path of the `project.json` of the wallpaper on that display or in that window (the main display's when neither is given). |

### Options

- `--file`: the wallpaper's `project.json`, its folder, or a file in its folder (a video's own
  file, as Wallpaper Engine takes). A folder in the library opens with its settings; any other
  wallpaper folder opens too. A web wallpaper must have been trusted once in the app (Set as
  Wallpaper asks), since the command line can't ask.
- `--monitor`: a display by number, from 0. The main display (the one with the menu bar) is 0;
  the others follow in the order macOS lists them.
- `--location`: a display by its identity: the UUID macOS gives it, as display profiles and an
  imported Wallpaper Engine `config.json` name it, or its display ID. A split display's region is
  the identity followed by `/L`, `/R`, `/T` or `/B` (and so on, for nested splits). For
  `close-wallpaper`, `apply-properties` and `get-wallpaper` it can also be a Play in Window
  window's name.
- `--preset`: one of the wallpaper's saved presets (Details › Your Presets), applied after it opens.
- `--properties`: a JSON object of property names and values, wrapped as Wallpaper Engine wraps it
  (`RAW~({"rate":10})~END`) or plain. A property's name is its key in `project.json`, as WE's
  Share JSON shows it; a colour is three numbers from 0 to 1 (`"schemecolor":"1 0 0"`).
- `--play-in-window`: opens the wallpaper in a window of that name instead of on a display, or
  shows it in the open window of that name. Wallpaper Engine's context menu uses the name
  "Wallpaper Pop-out". With it:
  - `--width` and `--height`: the window's size in pixels (default 1920 × 1080), shrunk to fit the
    screen if it's larger;
  - `--x` and `--y`: its top-left corner, in pixels from the main display's top-left corner
    (default: centred);
  - `--borderless`: no title bar or border (drag it by the wallpaper; close it with
    `close-wallpaper --location <name>`);
  - `--activate`: brings the window and the app to the front.

## Examples

```sh
# The wallpaper on the second display, in a script that changes it by time of day
"$OWE" --control open-wallpaper --file "$HOME/Wallpapers/Night/project.json" --monitor 1

# A phone-shaped preview window, then close it
"$OWE" --control open-wallpaper --file "$HOME/Wallpapers/Forest" --play-in-window Phone --width 607 --height 1080 --activate
"$OWE" --control close-wallpaper --location Phone

# Recolour the main display's wallpaper and print which wallpaper it is
"$OWE" -control applyProperties -properties 'RAW~({"schemecolor":"1 0 0"})~END'
"$OWE" --control get-wallpaper
```

## How it works

The executable started with `--control` doesn't open a second app: it hands the command to the
running app as a distributed notification of the login session and waits for the answer, then
exits. A development copy started with `OWE_ISOLATED_STATE=<tag>` (or `-OWEIsolatedState <tag>`)
takes commands only from a command line started with the same tag, and the user's app never sees
them. Like Wallpaper Engine's command line, any program you run can send these commands; the
app does nothing a command asks that its own controls wouldn't (a web wallpaper still needs your
trust first).

For AI assistants and other MCP clients, the [MCP Server](mcp.md) plugin controls the app with
more detail.
