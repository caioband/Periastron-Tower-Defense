# Skip wave

A vote to start the next wave before the current one ends (`StarterGui.Interface.SkipPrompt`).

**Runs in:** Game
**Code:** [`SkipService`](../../Game/src/Services/SkipService.luau), [`SkipPromptController`](../../Game/src/Controllers/SkipPromptController.luau), [`WaveService`](../../Game/src/Services/WaveService.luau), [`SkipConfig`](../../common/shared/Config/SharedConfig/SkipConfig.luau)

## How it works

The prompt has no button to open it.
It appears on its own `SkipConfig.OfferDelay` (5) seconds after the wave starts; `WaveService` records the start in `WaveStartedAt`.
`SkipService` checks every `PollInterval` (0.25 s) whether the vote should be on screen, and opens or closes it.

### When the prompt can appear

Besides the delay, `WaveService:CanSkipWave()` requires:

| Condition | Why |
| --- | --- |
| round `Running`, no game over | otherwise there is no wave to skip |
| `WaveAwaiter` exists | the round loop is waiting for **a wave** to end, not in the intermission |
| `MobService.AllMobsSpawned` | skipping mid-spawn would run two `SpawnWave` coroutines at once |
| `WaveCount < MaxWaves` | the last wave cannot be skipped: that would hand out the victory with enemies on the path |

**The vote belongs to the wave.**
Once open, it closes only when the wave can no longer be skipped (it ended on its own, it was skipped, or the round stopped), and votes count until then.

### The vote

A strict majority of the players in the server closes the vote (`SkipConfig.RequiredVotes`): one player decides alone, two must agree, four need three.
The counter shows **votes over votes required** (`1/3`), not over the player count.

- **Confirm** votes yes.
- **Cancel** removes the vote and hides the prompt **only for that player**, until the next vote.
  Each opening carries a new `token` from the server; a token the client has not dismissed shows normally.

The client sends `VoteSkip` with an explicit `wants` flag instead of toggling, so Cancel can remove a Confirm vote without the client knowing its state.
Players joining or leaving change the count for everyone, and a player leaving can close the vote if theirs was the missing one.
A player who joins mid-vote asks for the state with `RequestSkipState`.

### What skipping does

When the vote closes, `WaveService:SkipWave()` fires the same `Signals.Ended` that `MobService` fires when the last enemy dies.
For the round loop the wave is over, and it pays like any other (wave cash and farm income).
**The difference is on the map**: the remaining enemies keep walking, keep paying for damage and kills, and can still damage the base.
Skipping trades waiting for risk, not for a discount.

The two `Ended` signals do not interfere: nothing listens until the next wave calls `awaitWaveEnd`, and from then on `MobService` fires only when **every** living enemy is dead, leftovers included.

⚠️ That is why `SpawnWave` does **not** reset `ActiveMobCount`.
Resetting it would make the leftovers count against the new wave, and `Ended` would fire with enemies still on the map.
The number is always the count of living enemies: spawning adds, `removeMob` subtracts, and a round reset zeroes it.

### Animation

It is the same animation as the [center-screen warning](../common/screen-warnings.md): the prompt slides down from `SlideOffset` above its authored position while fading from fully transparent to its **authored** transparency.
The prompt has a transparent background, a 20% shadow, and an opaque image in the same tree; fading everything to zero would paint a solid box behind the art.
`SkipPromptController` reads each descendant's transparency once, at bind time, so repainting in Studio is enough.
`GuiObject.Transparency` is left out on purpose: it aliases `BackgroundTransparency`, and two tweens would fight over the same property.

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `SkipConfig.OfferDelay` | `5` | Seconds after the wave starts before the prompt appears |
| `SkipConfig.PollInterval` | `0.25` | How often the server checks whether to open or close |
| `SkipConfig.RequiredVotes(total)` | `floor(total / 2) + 1` | Votes needed |
| `SkipConfig.SlideOffset` / `FadeIn` / `FadeOut` | `0.06` / `0.35` / `0.25` | Animation |
| `SkipConfig.CountText` | `"%d/%d"` | Counter format |
