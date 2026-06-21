-- Credits: Discord: dankgang.3772 (Sariel) | Roblox: DankJang
--!strict

--[[
	HealthSystem
	one module, two classes glued together so you only require() once.

	Damageable -> just numbers + signals. no GUI stuff in here on purpose,
	            so I can reuse it on the server for real hp and on the client
	            for predicted hp without dragging UI code along.
	HealthGui  -> the view. binds to a Damageable and animates two bars:
	            a bright one that snaps to the new value and a grey one that
	            lags behind so you can see the chunk you just lost. stole the
	            idea from like every fighting game ever.

	the bars aren't resized frames - they're a colored frame masked by a
	UIGradient's transparency. cheaper than poking Size every frame and it
	doesn't care what shape the bar is.

	using a hand-rolled signal instead of BindableEvent so this still works
	in the command bar, in tests, and inside parallel actors.
]]

local RunService = game:GetService("RunService")

--==================================================================--
-- knobs                                                             --
--==================================================================--

-- how fast each bar chases its target. bright one snappy, grey one lazy.
-- tweak these to taste, they're not magic numbers.
local CURRENT_RATE = 20
local GREY_RATE = 6

-- the gradient needs two keypoints with *almost* the same time to fake a
-- hard edge. exactly the same time = roblox yells at you, too far apart
-- and the bar looks fuzzy. 0.001 is the sweet spot I landed on.
local SHARP_EPS = 0.001

-- once we're this close to the target just snap and bail. without this
-- the loop runs forever chasing floating point noise.
local DONE_EPS = 0.0005

--==================================================================--
-- types                                                             --
--==================================================================--

type Handler = (...any) -> ()

export type Connection = {
	Connected: boolean,
	Disconnect: (Connection) -> (),
}

export type Signal = {
	Connect: (Signal, Handler) -> Connection,
	Fire: (Signal, ...any) -> (),
	DisconnectAll: (Signal) -> (),
}

export type Damageable = {
	Instance: Instance,
	MaxHP: number,
	CurrentHP: number,
	HealthChanged: Signal,
	Died: Signal,
	Destroyed: Signal,

	ApplyDamage: (Damageable, amount: number, source: Instance?) -> number,
	Heal: (Damageable, amount: number) -> number,
	IsAlive: (Damageable) -> boolean,
	Destroy: (Damageable) -> (),
}

export type HealthGui = {
	Destroy: (HealthGui) -> (),
}

--==================================================================--
-- signal                                                            --
--==================================================================--
-- bare bones. flat array of handlers, Fire spawns each in its own thread
-- so one bad handler can't take down the rest. clone the list before
-- iterating so handlers can disconnect themselves mid-fire without blowing
-- up the loop - learned that one the hard way.

local function newSignal(): Signal
	local handlers: { Handler } = {}
	local signal = {} :: any

	function signal:Connect(handler: Handler): Connection
		table.insert(handlers, handler)
		local conn = { Connected = true } :: Connection
		function conn:Disconnect()
			-- guard against double-disconnects (people do it)
			if not self.Connected then return end
			self.Connected = false
			local i = table.find(handlers, handler)
			if i then table.remove(handlers, i) end
		end
		return conn
	end

	function signal:Fire(...)
		for _, h in ipairs(table.clone(handlers)) do
			task.spawn(h, ...)
		end
	end

	function signal:DisconnectAll()
		table.clear(handlers)
	end

	return signal
end

--==================================================================--
-- damageable                                                        --
--==================================================================--
-- holds the real hp number and fires events when it changes.
-- mobs, crates, vehicle armor pieces - anything that needs hp.

local Damageable = {}
Damageable.__index = Damageable

function Damageable.new(instance: Instance, maxHP: number): Damageable
	-- if you pass 0 every fraction calc downstream NaNs and you'll spend
	-- an hour wondering why your bar is broken. fail loud here.
	assert(maxHP > 0, "maxHP must be > 0")

	local self: any = setmetatable({
		Instance = instance,
		MaxHP = maxHP,
		CurrentHP = maxHP,
		HealthChanged = newSignal(),
		Died = newSignal(),
		Destroyed = newSignal(),
		-- underscore stuff is private. _alive flips once on first death
		-- so further damage just gets ignored cleanly.
		_alive = true,
		_destroyed = false,
	}, Damageable)
	return self
end

function Damageable:ApplyDamage(amount: number, source: Instance?): number
	local s = self :: any
	-- dead things don't take damage. negative amounts get dropped instead
	-- of secretly healing - had a bug like that once, never again.
	if not s._alive or amount <= 0 then return 0 end

	local before = s.CurrentHP
	local after = math.max(before - amount, 0)
	s.CurrentHP = after
	s.HealthChanged:Fire(after, before)

	if after == 0 then
		-- flip alive BEFORE firing Died, otherwise a Died handler that
		-- checks IsAlive() gets the wrong answer
		s._alive = false
		s.Died:Fire(source)
	end

	return before - after
end

function Damageable:Heal(amount: number): number
	local s = self :: any
	-- no resurrecting from heal. if you want res, make a new Damageable.
	if not s._alive or amount <= 0 then return 0 end

	local before = s.CurrentHP
	local after = math.min(before + amount, s.MaxHP)
	s.CurrentHP = after
	s.HealthChanged:Fire(after, before)
	return after - before
end

function Damageable:IsAlive(): boolean
	return (self :: any)._alive
end

function Damageable:Destroy()
	local s = self :: any
	if s._destroyed then return end
	s._destroyed = true
	s._alive = false
	-- fire Destroyed first so listeners get one last chance, then nuke
	-- the handler lists so closures can actually be collected
	s.Destroyed:Fire()
	s.HealthChanged:DisconnectAll()
	s.Died:DisconnectAll()
	s.Destroyed:DisconnectAll()
end

--==================================================================--
-- gradient bar tricks                                               --
--==================================================================--
-- the bar is a flat colored frame with a UIGradient on top. the gradient
-- has a sharp step at "fraction" - left side fully visible, right side
-- fully transparent. no resizing, no layout work, looks the same at any
-- size or shape. wish I'd thought of this years ago.

local function ensureGradient(parent: GuiObject): UIGradient
	-- reuse an existing one if the artist already set up a nice color ramp
	local existing = parent:FindFirstChildOfClass("UIGradient")
	if existing then return existing end
	local g = Instance.new("UIGradient")
	g.Parent = parent
	return g
end

local function buildSequence(fraction: number): NumberSequence
	-- edge cases: at 0 or 1 the four-keypoint sequence collapses, and
	-- roblox refuses sequences where two keypoints share a Time value.
	-- just hand back the flat sequences for those.
	if fraction <= SHARP_EPS then return NumberSequence.new(1) end
	if fraction >= 1 - SHARP_EPS then return NumberSequence.new(0) end
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(fraction, 0),
		NumberSequenceKeypoint.new(math.min(fraction + SHARP_EPS, 1), 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function setFraction(g: UIGradient, fraction: number)
	g.Transparency = buildSequence(fraction)
end

-- framerate-independent lerp. (1 - exp(-rate*dt)) is the closed form of
-- exponential approach, so the bar moves the same amount per real second
-- whether you're at 30, 60, or 240 fps. if you've ever written
-- "current = lerp(current, target, 0.1)" in a render loop, this is the
-- fix for that.
local function approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

local function stepBar(g: UIGradient, displayed: number, target: number, rate: number, dt: number): (number, boolean)
	-- snap when we're basically there. returns done=true so the outer
	-- loop can quit instead of grinding on noise forever.
	if math.abs(displayed - target) <= DONE_EPS then
		if displayed ~= target then setFraction(g, target) end
		return target, true
	end
	local next_ = approach(displayed, target, rate, dt)
	setFraction(g, next_)
	return next_, false
end

--==================================================================--
-- health gui                                                        --
--==================================================================--

local HealthGui = {}
HealthGui.__index = HealthGui

function HealthGui.new(damageable: Damageable, billboardGui: BillboardGui): HealthGui
	-- WaitForChild because PlayerGui / replicated stuff might not be in
	-- yet when we get here
	local container = billboardGui:WaitForChild("Container")
	local bar = container:WaitForChild("HealthBar")
	local grey = bar:WaitForChild("GreyHealth") :: GuiObject
	local current = bar:WaitForChild("CurrentHealth") :: GuiObject
	local healthText = container:WaitForChild("HealthText") :: TextLabel

	local self: any = setmetatable({
		damageable = damageable,
		currentGradient = ensureGradient(current),
		greyGradient = ensureGradient(grey),
		healthText = healthText,
		destroyed = false,
		lerpThread = nil,
	}, HealthGui)

	-- seed everything to the current hp so the bar pops in at the right
	-- size instead of animating from full or empty on the first frame
	local f = math.clamp(damageable.CurrentHP / damageable.MaxHP, 0, 1)
	self.currentDisplayed = f
	self.currentTarget = f
	self.greyDisplayed = f
	self.greyTarget = f
	self.lastHP = damageable.CurrentHP

	setFraction(self.currentGradient, f)
	setFraction(self.greyGradient, f)
	healthText.Text = `{damageable.CurrentHP} HP`

	-- the render loop only runs while a bar is actually moving. once
	-- both settle on target it dies. don't want a Heartbeat callback
	-- ticking on every idle health bar in the world.
	local function runLoop()
		while not self.destroyed do
			local dt = RunService.Heartbeat:Wait()
			if self.destroyed then break end

			local nextCurrent, currentDone = stepBar(self.currentGradient, self.currentDisplayed, self.currentTarget, CURRENT_RATE, dt)
			self.currentDisplayed = nextCurrent

			local nextGrey, greyDone = stepBar(self.greyGradient, self.greyDisplayed, self.greyTarget, GREY_RATE, dt)
			self.greyDisplayed = nextGrey

			-- text tracks the slow bar so the number ticks down at the
			-- same pace the bar drains. snapping the text feels gross.
			local hp = math.floor(nextGrey * self.damageable.MaxHP)
			if hp ~= self.lastHP then
				self.lastHP = hp
				self.healthText.Text = `{hp} HP`
			end

			if currentDone and greyDone then break end
		end
		self.lerpThread = nil
	end

	local function ensureLoop()
		-- only one loop at a time! two threads writing the same gradient
		-- = visual seizure
		if self.lerpThread and coroutine.status(self.lerpThread) ~= "dead" then return end
		self.lerpThread = task.spawn(runLoop)
	end

	self.healthChangedConn = damageable.HealthChanged:Connect(function(newHP, oldHP)
		if self.destroyed then return end
		local fraction = math.clamp(newHP / damageable.MaxHP, 0, 1)

		-- heals just snap. the grey trail is the "ouch you took damage"
		-- signal, animating heals the same way would lie to the player.
		if newHP >= oldHP then
			self.currentTarget = fraction
			self.greyTarget = fraction
			self.currentDisplayed = fraction
			self.greyDisplayed = fraction
			self.lastHP = newHP
			setFraction(self.currentGradient, fraction)
			setFraction(self.greyGradient, fraction)
			self.healthText.Text = `{newHP} HP`
			return
		end

		-- damage: just move the targets and wake the loop, let physics
		-- (well, exponentials) do the rest
		self.currentTarget = fraction
		self.greyTarget = fraction
		ensureLoop()
	end)

	-- if the Damageable goes away, take the bar with it. saves callers
	-- from having to remember a matching :Destroy()
	self.diedConn = damageable.Died:Connect(function() self:Destroy() end)
	self.destroyedConn = damageable.Destroyed:Connect(function() self:Destroy() end)

	return self
end

function HealthGui:Destroy()
	local s = self :: any
	if s.destroyed then return end
	s.destroyed = true
	-- drop our connections. don't bother killing the render thread by
	-- hand, it'll see the flag on its next Heartbeat and bail.
	s.healthChangedConn:Disconnect()
	s.diedConn:Disconnect()
	s.destroyedConn:Disconnect()
end

--==================================================================--
-- exports                                                           --
--==================================================================--
-- one require, both classes:
--   local HS = require(HealthSystem)
--   local mob = HS.Damageable.new(part, 100)
--   local gui = HS.HealthGui.new(mob, billboard)

return {
	Damageable = Damageable,
	HealthGui = HealthGui,
}
