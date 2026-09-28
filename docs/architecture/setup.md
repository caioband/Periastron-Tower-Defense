# Setup

How to check that a structural change did not break loading.

Installing the toolchain, syncing a place into Studio, and building a place file are covered in the [development setup](../../README.md#development-setup) in the root README.

## Check the load after changing the structure

`rojo build` only proves that the project assembles.
It does **not** catch a broken relative path.

The trap is a module that moves and uses `script.Parent`.
For example, a config module that walks `script.Parent.Parent` expecting to be in `Shared.Config` hangs forever on a `WaitForChild` once it moves to `ServerScriptService.Config`.
Every Service requires its config at the top of the file, so the server's `Me:Load()` never finishes and **no** server event is registered.
The symptom shows up on the client: dozens of `Serdes: X is taking too long to retrieve` warnings (see [Declare server events](me-framework.md#declare-every-server-to-client-event-on-the-server)).

After moving anything, press Play and run this on the server:

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local Me = require(game.ReplicatedStorage.Shared.Vendor.Me)

local expected = 0
for _, item in ServerScriptService.Services:GetDescendants() do
    if item:IsA("ModuleScript") then expected += 1 end
end

local loaded = 0
for _ in Me.new().Loaded do loaded += 1 end

print("services loaded:", loaded, "of", expected)
```

`loaded` can be lower than `expected` only when a module returns a function instead of a table (`Me` skips those).
If it is lower for any other reason, a module is stuck on a `WaitForChild`: look for `script.Parent` in whatever you moved.
