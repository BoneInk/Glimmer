# Playlists

A playlist (the Playlists tab) rotates its wallpapers on the displays it plays on. Its settings
follow Wallpaper Engine 2.8's Playlist Settings dialog, with WE's semantics and WE's stored keys
and values; Configure in the playlist's header opens them.

## When it changes wallpaper

"Change wallpaper" (WE's `settings.mode`):

| Choice | Value | What it does |
|---|---|---|
| When logging in | `logon` | One step each time the app starts (it starts at login), in the playlist's order or shuffled. |
| On a timer | `timer` | Every *Wallpaper duration*, or when a video ends with *Change wallpaper when a video ends*. The default. |
| Time of day | `daytime` | Each wallpaper has a slot of the day; the playlist shows the one whose slot it is. |
| Day of week | `dayofweek` | Up to seven wallpapers share the week; the playlist shows today's. |
| Never | `never` | Only Next and Previous change it. |

- **Time of day.** Each item stores where its slot ends as a fraction of the day (WE's
  `daytimeend`). The first slot starts at midnight, each next one where the previous ends, and
  the last runs to midnight (it never has an end). Items without an end share the time up to the
  next end evenly, as WE's timeline lays them out (`flex`). An end before the one above it is
  dropped, and the ends are dropped when the playlist leaves Time of day, as WE's dialog does.
  Ends snap to five minutes for playlists of up to 50 items. Times are wall-clock times: 08:00 is
  08:00 on the days the clocks change, and a time the clocks skip starts at the first moment after
  it (`PlaylistSchedule`).
- **Day of week.** The first seven items share the week from its first day (the locale's first
  weekday, WE's `dayofweekoffset`): with `n` items, item `r` gets `floor(left / (n − r))` days and
  the last the rest, as WE labels them (three items: Mon–Tue, Wed–Thu, Fri–Sun). WE doesn't take an
  eighth: adding one is refused, and saving the settings of a longer playlist asks to remove the
  rest.
- **Recomputing.** One timer waits for the next slot (no polling). The Mac waking, the session
  becoming active, the clock or time zone changing and the day changing look again
  (`PlaylistClockObserver`). Next and Previous stay until the slot changes; the slot's wallpaper
  then shows again.
- Scheduled playlists ignore Shuffle and Repeat: the slot picks the wallpaper.

## The timer's options

WE's dialog offers these only on a timer, and they apply only there:

- **Change wallpaper when a video ends** (`videosequence`): a video moves on when it ends rather
  than after the duration.
- **Allow wallpaper to change while paused** (`updateonpause`): without it, the timer stands still
  while the wallpaper is paused (Pause in the menu bar menu, or the playback rules pausing or
  stopping every display the playlist shows on) and runs on from where it stopped
  (`PlaylistCountdown`).
- **Always begin with the first wallpaper** (`beginfirst`): the playlist starts at its first item
  when the app starts or the playlist is started, not where it left off.
- **First wallpaper played at startup only** (`playintro`, with the above): the first item plays
  when the playlist starts, and the rotation, Next and Previous leave it out after.

## Transitions

WE's transitions between wallpapers (`settings.transition`, `transitionpool`, `transitiontime`):
None (reduce flicker), None, Random, or one of 27 kinds: Fade, Fade to black, Mosaic, Diffuse,
Horizontal slide, Vertical slide, Horizontal fade, Vertical fade, Clouds, Burnt paper, Circular,
Zipper, Door, Lines, Radial wipe, Zoom, Drip, Pixelate, Bricks, Paint, Twister, Black hole, CRT,
Glass shatter, Bullets, Ice and Boilover. Random picks from the kinds ticked in its pool (all by
default; WE stores no pool then). The time is 0 to 3000 ms in 50 ms steps. A new playlist fades
over 1500 ms, as in WE; a playlist saved before transitions has none.

Settings › General › Transitions is WE's "Wallpaper browser transition" (`browsetransition`): the
same choices for a wallpaper chosen in the library. It is off until you choose one, as in WE.
Other changes (application rules, the control channel, restoring at launch) don't transition.

How they play (`App/Transitions/`):

- The kinds are Metal ports of WE's own transition shader (`dx11playlisttransition`, one kind per
  `FADEEFFECT`), with its geometry shader's bricks drawn as instances, its Voronoi facets
  (`CreateVoronoiFacets`) generated for Glass shatter, its gaussian (`dx11playlistgaussian`)
  building the blurred mip chain CRT and Ice sample, and Boilover reading WE's `noise.png` and
  `clouds_256.png` from the assets (generated stand-ins without them).
- The outgoing wallpaper's picture is captured first: a scene's current moment drawn again into a
  texture that stays on the GPU, an AVKit video's current frame, a page's snapshot or a Chromium
  page's frame. The change then applies, the outgoing wallpaper stops as it would without a
  transition, and the incoming one runs live underneath.
- Its clock starts when the change asks for it, as WE's transition window's does: progress stays 0
  for WE's 0.1 s lead-in (the capture and setup included), then runs over the time.
- Each frame the transition draws the outgoing picture with its coverage (premultiplied) once per
  changing wallpaper into an IOSurface, which an overlay layer in each display's window shows; the
  compositor lays it over the incoming wallpaper. A clone's and a stretch's displays show the one
  render (a stretch's each its rect of the canvas); a split region shows it in its rect. When the
  time is up the overlays leave and the picture and frames are freed.
- The playlist's sheet previews the chosen transition on two of its wallpapers' previews.

## Control channel

`playlist_update` sets all of these (`change_wallpaper`, `change_while_paused`,
`begin_with_first_wallpaper`, `first_wallpaper_at_startup_only`, `daytime_ends`, `transition`,
`transition_pool`, `transition_time_ms`) and returns them with each slot; see [mcp.md](mcp.md).
