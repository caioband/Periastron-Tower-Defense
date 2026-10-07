# Gifting

A player buys a game pass or a coin pack for another player, online or not.
Roblox has no native gifting, so every gift is a **developer product** the buyer pays for, and the game hands the item to the recipient.

**Runs in:** Game · Lobby
**Code:** [`GiftService`](../../common/server/Services/GiftService.luau), [`GiftConfig`](../../common/shared/Config/SharedConfig/GiftConfig.luau), [`Config.Gifting`](../../common/server/Config/Gifting.luau), [`MonetizationService`](../../common/server/Services/MonetizationService.luau), [`DataService`](../../common/server/Services/DataService.luau)

There is no client UI yet: the server events below are ready for it, and the `gift` command exercises the whole flow in QA.

## What can be gifted

`GiftConfig.ITEMS`, keyed by an item key that is stored in profiles (never rename one):

| Item | Kind | Gives |
| --- | --- | --- |
| `VIP`, `Shards`, `Luck`, `CardSlots`, `Coins`, `Speed` | Pass | the `GamepassConfig.PASSES` pass of the same name |
| `Pack1`, `Pack2`, `Pack3` | Pack | the coin pack with that `ProductId` in `RobuxShopConfig.PACKS` (200, 1,400, 7,000 coins) |

Each item has its **own** gift product (`ProductId`), never the pass or the pack itself: a receipt only says who paid and for which product, so a gift and a purchase for oneself must be different products.
Price each gift product like what it gives.
An item whose `ProductId` is `0` cannot be bought, but gifts of it already paid for still pay out.

## How it works

### 1. The buyer asks (`RequestGift`)

The client fires `RequestGift(requestId, recipientId, itemKey, message)` and gets `GiftRequestResult { Id, Success, Reason }`.
The server checks, in order: busy and cooldown, the item, the recipient id, not a self gift, the buyer's profile, the item's lock (see below), friends (only with `FRIENDS_ONLY`), the recipient's status (exists, has a profile, inbox not full, does not own the pass, no gift of that pass pending), and the message.

It then writes an **intent** in `Data.Gifts.Outgoing[itemKey]` (recipient, message, `State = "Prompt"`), **waits for the save**, and only then opens the purchase prompt.
If the server crashes after the purchase, the receipt still finds the intent on the next server.

**One intent per item, so it is locked while in use.**
A second gift of the same item would replace the intent, and a receipt still pending would go to the new recipient.
So `RequestGift` refuses with `PurchasePending` while:

- the prompt is open (`State = "Prompt"`, up to `PROMPT_LOCK`), or
- Roblox said it was bought (`PromptProductPurchaseFinished`, `State = "Paid"`) and the receipt has not consumed it yet (up to `PAID_LOCK`).

Closing the prompt without buying removes the intent at once, so a cancelled gift neither blocks the next one nor waits around for a purchase made some other way.

### 2. The receipt (`_onPurchase`)

The receipt arrives through `MonetizationService:RegisterProduct`, like every product, so `PurchaseHistory` and the save before `PurchaseGranted` make it pay once.
The gift id is the receipt's `PurchaseId`.

- With a usable intent, the gift goes to its recipient, and the intent is marked `ConsumedBy = <gift id>`.
- With no intent (a prompt opened some other way), the buyer paid, so the buyer gets it.
- A recipient with no profile at all also falls back to the buyer.

### 3. Delivery (`_route`)

- **Recipient on this server:** straight into their `Data.Gifts.Inbox`, and their profile is **saved** before the receipt is confirmed (the receipt only saves the buyer).
- **Anywhere else, or offline:** a ProfileStore message (`Kind = "Gift"`), the same road as `ProfileEditService`. A recipient with no open session gets a short session that moves the message into the inbox; if that times out, nothing is lost, and the message applies on their next join.

The inbox write ignores a gift id it has already seen (`Inbox` or `Received`), so a receipt retried after a crash never delivers twice.

### 4. The claim (`Deliver` / `_claim`)

When the profile opens (in the Lobby, once the client is ready), or when a gift arrives, every inbox entry is paid out:

- **Pass:** recorded in `Data.GiftedPasses`, which `MonetizationService:RecalibratePasses` merges into `Gamepasses` on every join. This is the one pass that *is* stored in the profile: Roblox does not know about gifts.
- **Pass they already own:** coins instead, `Config.Gifting.DUPLICATE_COINS[passKey]`, and no gift record. This happens when two buyers race, or when a gift falls back to a buyer who owns the pass.
- **Pack:** `RobuxShopService:Grant`.

The payout and the inbox removal happen with nothing yielding in between.
The client gets `GiftNotification { Type = "Received", ..., Duplicate, Coins }`, and the entry stays in `Data.Gifts.Unseen` until the client fires `GiftSeen(giftId)` (or `nil` for all).
The buyer gets `GiftNotification { Type = "Sent", ... }` when the receipt routes.

A claim that cannot complete (currency not ready) is retried `DELIVER_MAX_ATTEMPTS` times, `DELIVER_RETRY_DELAY` apart, and again on the next join.

### Looking up a recipient

`LookupGiftRecipient(requestId, query)` takes a username or a UserId and answers `GiftLookupResult { Id, Success, UserId, Username, Owned, Pending }` for the UI: which giftable passes that user already owns or has waiting.
It is a display, never a decision: `RequestGift` asks again.

A recipient off this server costs one DataStore read, so lookups have a per-player cooldown (`LOOKUP_COOLDOWN`), reuse a recent answer for the same user (`LOOKUP_CACHE_SECONDS`), and stop while the server's GetAsync budget is under `LOOKUP_MIN_BUDGET`, so they never compete with profile loads and saves.

"Pending" counts gifts in the inbox **and** gifts still in the message queue, so two buyers cannot both gift the same pass while the first one is in transit.

### The message

Free text, up to `GiftConfig.MAX_MESSAGE_LENGTH` characters, filtered by `TextService` for the recipient.
It is direct communication between two users, so it is gated like a private message: it is only kept when `TextChatService:CanUserChatAsync(buyer)` and `CanUsersDirectChatAsync(buyer, { recipient })` allow it.
If either says no, or anything fails, the gift goes **without** the message.

## Configuration

`Config.Gifting` (server only):

| Key | Effect |
| --- | --- |
| `REQUEST_COOLDOWN` | Seconds between two gift requests from one player |
| `LOOKUP_COOLDOWN` | Seconds between two lookups from one player |
| `LOOKUP_CACHE_SECONDS` | How long a lookup answer is reused for the same recipient |
| `LOOKUP_MIN_BUDGET` | GetAsync budget under which lookups are refused |
| `MAX_INBOX` | Unclaimed gifts a recipient may have; only checked when a gift starts |
| `RECEIVED_CAP`, `UNSEEN_CAP` | Claimed ids kept for dedupe, and unseen toasts kept |
| `FRIENDS_ONLY` | Only friends of the buyer can be gifted |
| `PROMPT_LOCK`, `PAID_LOCK` | Fallback lengths of the intent lock (see step 1) |
| `DUPLICATE_COINS` | Coins per pass key for a pass gift the recipient already owns; `0` = none |
| `DELIVER_RETRY_DELAY`, `DELIVER_MAX_ATTEMPTS` | Claim retries |
| `OFFLINE_SESSION_TIMEOUT` | How long the short session waits for an offline profile |

## Testing

In QA and Studio, admins have two commands (see [Admin commands](admin-commands.md)):

- `gift <players> <item>` runs the receipt path with a fake `PurchaseId`, skipping the Robux prompt, and logs every check.
- `giftreset [players]` empties `GiftedPasses` and the gift tables of players on this server, and re-checks passes with Roblox. Without it, a pass from `gift` stays on the test profile for good.

## Design notes

- **Why the intent is saved before the prompt, and `DataService:Save` waits.** `ProfileStore`'s `Save` only starts a save. `DataService:Save` stamps the data (`SaveStamp`) and waits for a save carrying that stamp, so "saved" means on disk, not queued.
- **Why the lookup can show what someone owns.** The UI needs it to grey out passes that cannot be gifted. It only covers giftable passes.
- **Why a duplicate pays coins and not a refund.** Robux cannot be refunded from the game. Set `DUPLICATE_COINS` close to the gift's price.
