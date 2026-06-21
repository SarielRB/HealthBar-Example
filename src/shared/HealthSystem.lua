-- Credits: Discord: kctwisten (Sariel) | Roblox: DankJang
--!strict

--[[
	HealthSystem
	------------
	A single, self-contained ModuleScript that bundles two cooperating classes:

	  1. Damageable  - a logical health container exposing health math + signals
	                   (HealthChanged, Died, Destroyed). It is purely data and
	                   contains zero rendering code so it can be reused on the
	                   server (authoritative) or client (visual prediction).

	  2. HealthGui   - a view/controller that binds a Damageable to a BillboardGui
	                   and animates two stacked bars: a fast "current" bar that
	                   snaps to the new value and a slow "grey" bar that trails
	                   behind to communicate how much damage was just taken
	                   (a pattern used in many fighting/MOBA games).

	The animation is driven by a UIGradient.Transparency NumberSequence rather
	than by resizing a Frame. This avoids any reflow/layout cost on the GUI
	hierarchy and allows the bar to be skewed, rounded, or shaped without the
	usual scaling artifacts. The fraction is encoded as a sharp step in the
	gradient: pixels left of the step are fully opaque, pixels right of it
	are fully transparent.

	A custom lightweight Signal implementation is used instead of BindableEvents
	so the module also works inside the studio command bar, in tests, and inside
	parallel Luau actors where BindableEvents are restricted.
]]

local RunService = game:GetService("RunService")

--==================================================================--
-- TUNABLES                                                          --
--==================================================================--

-- Higher rate = bar catches up to its target faster. These values are tuned
-- so that the bright bar feels "responsive" while the grey bar feels "heavy".
local CURRENT_RATE = 20  -- per-second exponential approach rate for bright bar
local GREY_RATE = 6      -- per-second exponential approach rate for trailing bar

-- Epsilons used to make the gradient render a perfectly sharp edge.
-- SHARP_EPS controls the width of the transition keypoints; if it is too
-- large the bar looks blurry, if it is exactly 0 Roblox rejects the sequence
-- because two keypoints would share the same Time value.
local SHARP_EPS = 0.001

-- Once the displayed value is within DONE_EPS of the target we snap and bail
-- out of the render loop. This avoids the loop running forever at floating
-- point noise levels (~1e-7) and burning Heartbeats for no visible change.
local DONE_EPS = 0.0005

--==================================================================--
-- TYPES                                                             --
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
-- SIGNAL                                                            --
--==================================================================--
-- A minimal, allocation-light signal. Handlers are stored in a flat array
-- which makes Fire O(n) but keeps Connect/Disconnect O(1) amortized.
-- Fire clones the handler list before iterating so a handler is allowed to
-- disconnect itself (or others) during dispatch without invalidating
-- iteration -- a footgun that BindableEvents do not have to worry about.

local function newSignal(): Signal
	local handlers: { Handler } = {}
	local signal = {} :: any

	function signal:Connect(handler: Handler): Connection
		table.insert(handlers, handler)
		local conn = { Connected = true } :: Connection
		function conn:Disconnect()
			-- Guard against double-disconnects; table.find on an absent
			-- handler returns nil, but the boolean keeps us from doing
			-- the lookup twice for the common case.
			if not self.Connected then return end
			self.Connected = false
			local i = table.find(handlers, handler)
			if i then table.remove(handlers, i) end
		end
		return conn
	end

	function signal:Fire(...)
		-- task.spawn makes each handler run in its own thread so a single
		-- yielding/erroring handler can never stall siblings.
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
-- DAMAGEABLE                                                        --
--==================================================================--
-- Pure-logic class. Holds the canonical HP value and notifies observers.
-- Anything that wants to "have health" (a mob, a destructible crate, a
-- vehicle's armor segment) just wraps itself in one of these.

local Damageable = {}
Damageable.__index = Damageable

function Damageable.new(instance: Instance, maxHP: number): Damageable
	-- We refuse zero/negative maxHP because every downstream calculation
	-- (CurrentHP/MaxHP fractions, healing caps) would either NaN or be
	-- meaningless. Failing loudly here saves hours of debugging later.
	assert(maxHP > 0, "maxHP must be > 0")

	local self: any = setmetatable({
		Instance = instance,
		MaxHP = maxHP,
		CurrentHP = maxHP,
		HealthChanged = newSignal(),
		Died = newSignal(),
		Destroyed = newSignal(),
		-- Underscore-prefixed fields are private bookkeeping. _alive flips
		-- once on the first kill so further damage is ignored cleanly.
		_alive = true,
		_destroyed = false,
	}, Damageable)
	return self
end

function Damageable:ApplyDamage(amount: number, source: Instance?): number
	local s = self :: any
	-- Dead things take no damage, and zero/negative amounts are silently
	-- dropped instead of being routed through Heal (which would be a
	-- subtle bug where ApplyDamage(-10) heals 10).
	if not s._alive or amount <= 0 then return 0 end

	local before = s.CurrentHP
	local after = math.max(before - amount, 0)
	s.CurrentHP = after
	s.HealthChanged:Fire(after, before)

	if after == 0 then
		-- Flip the alive flag BEFORE firing Died so a Died handler that
		-- queries IsAlive() sees the correct (dead) state.
		s._alive = false
		s.Died:Fire(source)
	end

	return before - after
end

function Damageable:Heal(amount: number): number
	local s = self :: any
	-- Dead entities cannot be healed by default; resurrection is a higher
	-- level concept that callers can model by creating a fresh Damageable.
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
	-- Fire Destroyed BEFORE wiping the connection lists so listeners get a
	-- final chance to react; then drop references so handler closures are
	-- collectable even if some outside code keeps holding the Signal table.
	s.Destroyed:Fire()
	s.HealthChanged:DisconnectAll()
	s.Died:DisconnectAll()
	s.Destroyed:DisconnectAll()
end

--==================================================================--
-- GRADIENT HELPERS                                                  --
--==================================================================--
-- The bar is rendered by masking a colored Frame with a UIGradient's
-- Transparency channel. By placing a hard step in the NumberSequence at
-- "fraction", the left portion stays visible and the right portion is
-- erased -- giving us a crisp, scalable health bar with zero layout work.

local function ensureGradient(parent: GuiObject): UIGradient
	-- Idempotent: reuse a designer-authored UIGradient if one exists so the
	-- artist's chosen color ramp is preserved; otherwise create a default.
	local existing = parent:FindFirstChildOfClass("UIGradient")
	if existing then return existing end
	local g = Instance.new("UIGradient")
	g.Parent = parent
	return g
end

local function buildSequence(fraction: number): NumberSequence
	-- Degenerate edges have to be handled explicitly because two keypoints
	-- can never share the same Time, and a sequence with a step at 0 or 1
	-- collapses to a flat NumberSequence anyway.
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

-- Framerate-independent exponential approach. The (1 - exp(-rate * dt))
-- factor is the analytic solution to an exponential lerp, so the bar moves
-- the same visible distance per unit of real time regardless of whether
-- Heartbeat fires at 30, 60, or 240 Hz.
local function approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

local function stepBar(g: UIGradient, displayed: number, target: number, rate: number, dt: number): (number, boolean)
	-- Snap and signal "done" when we are visually indistinguishable from
	-- the target; this lets the outer loop exit instead of running forever.
	if math.abs(displayed - target) <= DONE_EPS then
		if displayed ~= target then setFraction(g, target) end
		return target, true
	end
	local next_ = approach(displayed, target, rate, dt)
	setFraction(g, next_)
	return next_, false
end

--==================================================================--
-- HEALTH GUI                                                        --
--==================================================================--

local HealthGui = {}
HealthGui.__index = HealthGui

function HealthGui.new(damageable: Damageable, billboardGui: BillboardGui): HealthGui
	-- WaitForChild lets us tolerate the GUI streaming in slightly after the
	-- module attaches, which is common with PlayerGui / replicated assets.
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

	-- Seed the displayed/target values to match the starting HP so the bar
	-- pops in at the right size on the first frame rather than animating
	-- in from full or empty.
	local f = math.clamp(damageable.CurrentHP / damageable.MaxHP, 0, 1)
	self.currentDisplayed = f
	self.currentTarget = f
	self.greyDisplayed = f
	self.greyTarget = f
	self.lastHP = damageable.CurrentHP

	setFraction(self.currentGradient, f)
	setFraction(self.greyGradient, f)
	healthText.Text = `{damageable.CurrentHP} HP`

	-- The render loop only exists while a bar is mid-animation. As soon as
	-- both bars settle on their target we let it die so we are not paying
	-- a Heartbeat callback per idle health bar in the world.
	local function runLoop()
		while not self.destroyed do
			local dt = RunService.Heartbeat:Wait()
			if self.destroyed then break end

			local nextCurrent, currentDone = stepBar(self.currentGradient, self.currentDisplayed, self.currentTarget, CURRENT_RATE, dt)
			self.currentDisplayed = nextCurrent

			local nextGrey, greyDone = stepBar(self.greyGradient, self.greyDisplayed, self.greyTarget, GREY_RATE, dt)
			self.greyDisplayed = nextGrey

			-- The text mirrors the slow (grey) bar so the number counts
			-- down at the same pace the player sees their health draining,
			-- which feels more honest than snapping straight to the value.
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
		-- Reuse a running coroutine; never spawn a second one in parallel,
		-- otherwise two threads would race to write the same UIGradient.
		if self.lerpThread and coroutine.status(self.lerpThread) ~= "dead" then return end
		self.lerpThread = task.spawn(runLoop)
	end

	self.healthChangedConn = damageable.HealthChanged:Connect(function(newHP, oldHP)
		if self.destroyed then return end
		local fraction = math.clamp(newHP / damageable.MaxHP, 0, 1)

		-- Heals are snapped instantly. The grey-trail aesthetic exists to
		-- communicate "damage just happened"; animating heals the same way
		-- would imply damage and confuse the player.
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

		-- For damage, just update the targets and wake the render loop;
		-- the bright bar will race ahead and the grey bar will catch up.
		self.currentTarget = fraction
		self.greyTarget = fraction
		ensureLoop()
	end)

	-- Auto-clean when the underlying Damageable goes away so callers do
	-- not have to remember a paired :Destroy() call.
	self.diedConn = damageable.Died:Connect(function() self:Destroy() end)
	self.destroyedConn = damageable.Destroyed:Connect(function() self:Destroy() end)

	return self
end

function HealthGui:Destroy()
	local s = self :: any
	if s.destroyed then return end
	s.destroyed = true
	-- Disconnect every signal we own. The render loop will notice the
	-- destroyed flag on its next Heartbeat and exit by itself, so we do
	-- not need to forcibly cancel the coroutine.
	s.healthChangedConn:Disconnect()
	s.diedConn:Disconnect()
	s.destroyedConn:Disconnect()
end

--==================================================================--
-- MODULE EXPORT                                                     --
--==================================================================--
-- Both classes are returned from a single table so consumers do a single
-- require() and grab whichever piece they need:
--     local HS = require(HealthSystem)
--     local mob = HS.Damageable.new(part, 100)
--     local gui = HS.HealthGui.new(mob, billboard)

return {
	Damageable = Damageable,
	HealthGui = HealthGui,
}
