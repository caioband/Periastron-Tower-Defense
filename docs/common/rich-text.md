# Rich text

`RichTextController` draws text that types itself out letter by letter, shakes, changes color mid-sentence, carries inline images, and reports when it reaches a point.
Every screen in the game talks to it; none talks to the underlying library.

**Runs in:** Game · Lobby (client)
**Code:** [`RichTextController`](../../common/client/Controllers/RichTextController/init.luau), [`Backends/`](../../common/client/Controllers/RichTextController/Backends), [`RichTextLabController`](../../common/client/Controllers/RichTextLabController.luau), [`RichTextLabService`](../../common/server/Services/RichTextLabService.luau), [`RichTextConfig`](../../common/shared/Config/SharedConfig/RichTextConfig.luau)

## Usage

```lua
local RichText = Framework:Get("RichTextController")

RichText:Write(label, "WARNING! [shake]FOG[/shake] COMING IN 3 ROUNDS", {
    Preset = "Warning",
})
```

A container that receives several sentences (an NPC line, a tutorial) keeps a handle:

```lua
local handle = RichText:Bind(dialogueFrame, { Preset = "Dialogue" })

handle:OnFinished(function(skipped)
    prompt.Visible = true
end)

handle:Write("Welcome, [color=yellow]commander[/color].[pause=1] Take a seat.")
```

- **Handle:** `:Write`, `:Skip` (show everything now: what a player's click mid-line should do), `:Pause`, `:Resume`, `:Clear`, `:SetOptions`, `:Fit`, `:GetText`, `:IsWriting`, `:OnFinished`, `:OnEvent`, `:Destroy`.
- **Controller:** `:Write`, `:Clear`, `:Release`, `:FitSize`, `:AwaitLayout`, `:Escape`, `:Plain`, `:GetBackend`.

## Markup

`[name]text[/name]` wraps a span, `[name]` marks a point, and `[name=value]` takes a value.
The list lives in `RichTextConfig.Aliases`:

| Markup | What it does |
| --- | --- |
| `[b] [i] [u] [s]` | bold, italic, underline, strikethrough |
| `[color=red] [size=40] [font=...] [trans=.5]` | look of a span |
| `[stroke] [shadow] [mark]` | outline, shadow, highlighter |
| `[shake] [wiggle] [rainbow] [fog]` | effects |
| `[shiny=yellow] [gradient=orange] [gold]` | sparkle, palette gradient (`RichTextConfig.Gradients`), and shiny gold |
| `[br] [pause=1] [speed=40]` | line break, typing pause, pace from here on |
| `[img=123]` | an image mid-sentence |
| `[event=name]` | fires `handle:OnEvent` when typing reaches it |

**Only what is in the table is a tag.**
Any other bracket is plain text, so `[1]` in a sentence stays `[1]` and a misspelled alias shows on screen instead of vanishing.
`[[` writes a literal bracket.

A raw library tag (`<anim=bounce dur=2>`) still passes through untranslated.
It is the escape hatch for what is not an alias yet, and it ties the caller to HyperText: used twice, it becomes an alias.

### Player text goes through `:Escape()`

Player names, chat messages, anything a player typed:

```lua
RichText:Write(label, `{RichText:Escape(player.DisplayName)} joined the lobby`)
```

`:Escape()` doubles brackets and replaces `<` with `‹` (a similar single-width character).
The second is required: HyperText treats `<` as the start of a tag and would swallow the rest of the sentence.

## Options and presets

What applies to the whole sentence goes in an options table: `Speed` (in **characters per second**; the backend converts), `Size`, `Fit`, `Color`, `Font`, `Weight`, `Italic`, `Transparency`, `Stroke`, `Shadow`, `Anim`/`AnimDuration`/`AnimLoop`, `Sound`/`SoundVolume`, `Align`, `VerticalAlign`, `ZIndex`, `Wrapped`, `Yield`.

Named combinations live in `RichTextConfig.Presets` (today `Instant`, `Warning`, and `Dialogue`).
Game code names the preset; fine-tuning belongs to the designer.
The order is `Defaults` < preset < the call's options.

> Options passed to `:Write()` **stay** on the handle, as if `:SetOptions()` ran before the text.
> They become renderer configuration, and undoing them per sentence would cost a rebuild per sentence.

## Text size from the box (`Fit`)

`Size` is in pixels, and pixels do not translate between screens: 12 px is a fifth of a box on a monitor and half of it on a phone.
`Fit` replaces the number with a measurement of the box at write time:

```lua
RichText:Write(label, "WAVE 12 INCOMING", { Fit = true })

-- or overriding the defaults in RichTextConfig.Fit:
RichText:Write(label, longLine, { Fit = { MaxRows = 3, MaxTextSize = 48 } })
```

The text size is the smaller of two walls: the box **height** times `TextRatio`, and the box **width** against the sentence's real width, measured by `TextService` and cached per sentence and font (`WidthPerChar` is only the fallback when measuring fails).
Both are divided by the number of **rows**, which keeps a long sentence from becoming tiny: the controller tries 1 to `MaxRows` rows and keeps the one that gives the **largest** text.
`MinTextSize` is the floor and `MaxTextSize` the ceiling.

> `Fit` makes the write **yield**: it waits for a stable box size (`:AwaitLayout`) and measures width asynchronously.
> Code inside a click handler already runs in its own thread; anything else should use `task.spawn`.

If the screen size changes later, `handle:Fit()` with no argument re-measures from the last sentence.

**Several sibling pieces with one size** do not use `Fit`, since each would measure its own sentence.
Ask for the size once and share it (as the [weather indicator](../game/weather-in-match.md#effect-lines) does):

```lua
RichText:AwaitLayout(firstLine)

local size = RichText:FitSize(firstLine, texts, Config.Text, Config.Line.Fit)

for _, handle in handles do
    handle:Write(markup(...), { Size = size })
end
```

With `RichTextConfig.Fit.Debug`, Studio logs **which wall** decided each size.
Without it, tuning a box is guesswork: `TextRatio` does nothing when width limits, and `MaxRows` does nothing when height limits.

## The workbench (`richtext` command)

The `richtext` [admin command](admin-commands.md) opens `RichTextLabController`: a text box for markup, a **DISPLAY** button, and a container where the result renders, plus **CLEAR** and a **PRESET** button that cycles `Defaults`, `Dialogue`, `Instant`, and `Warning`.
Running the command again closes it.

- **The screen is built in code**, because `StarterGui` is not synced by Rojo and a dev tool that depends on someone having the place open would not be in git.
- **Changing preset releases the handle and creates another.**
  A handle's options accumulate, and on a workbench that would show a mix no real screen would have.
- **The server opens it** (`RichTextLabService`), through the same permission path as every command.

## Backends

`RichTextController/Backends/` has one module per technology, and `RichTextConfig.Backends` (`{ "HyperText", "Plain" }`) is the order of preference; the controller uses the first one that loads.

- **`HyperTextBackend`** is the real one and **the only file that knows HyperText exists**: it translates neutral options into the library's markups and aliases into its tags.
  It requires the vendor **late and inside a `pcall`**, because `Me:Load()` requires every descendant of `Controllers` in an unprotected loop, and a require error there would take down the whole client boot.
- **`PlainBackend`** is the fallback: it strips the markup and writes plain text into a `TextLabel`.
  If the vendor is missing or broken, warnings still show, plain but visible.
  In Plain, `[event=...]` does not fire and `OnFinished` fires as soon as the text is in.

**Switching technology** means writing a backend with the same methods (`Load`, `Tag`, `Create`, `Apply`, `Render`, `Skip`/`Pause`/`Resume`/`Clear`, `Destroy`, `IsRendering`, `GetText`, `OnFinished`, `OnEvent`), adding its column to `RichTextConfig.Aliases`, and putting its name first in `Backends`.
No screen changes.

**Updating HyperText** means copying upstream `src/HyperText` over `vendor/shared/HyperText`.
The copy has no local patches, and the vendored commit is recorded in `Attribution.luau`.
The module requires by string (`require("./Util")`), so the folder must keep its shape.
