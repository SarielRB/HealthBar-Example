--!strict

local RunService = game:GetService("RunService")

local Damageable = require(script.Parent:WaitForChild("Damageable"))

local CURRENT_RATE = 20
local GREY_RATE = 6
local SHARP_EPS = 0.001
local DONE_EPS = 0.0005

local HealthGui = {}
HealthGui.__index = HealthGui

export type HealthGui = {
	Destroy: (HealthGui) -> (),
}

local function ensureGradient(parent: GuiObject): UIGradient
	local existing = parent:FindFirstChildOfClass("UIGradient")
	if existing then return existing end
	local g = Instance.new("UIGradient")
	g.Parent = parent
	return g
end

local function buildSequence(fraction: number): NumberSequence
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

local function approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

local function stepBar(g: UIGradient, displayed: number, target: number, rate: number, dt: number): (number, boolean)
	if math.abs(displayed - target) <= DONE_EPS then
		if displayed ~= target then setFraction(g, target) end
		return target, true
	end
	local next_ = approach(displayed, target, rate, dt)
	setFraction(g, next_)
	return next_, false
end

function HealthGui.new(damageable: Damageable.Damageable, billboardGui: BillboardGui): HealthGui
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

	local f = math.clamp(damageable.CurrentHP / damageable.MaxHP, 0, 1)
	self.currentDisplayed = f
	self.currentTarget = f
	self.greyDisplayed = f
	self.greyTarget = f
	self.lastHP = damageable.CurrentHP

	setFraction(self.currentGradient, f)
	setFraction(self.greyGradient, f)
	healthText.Text = `{damageable.CurrentHP} HP`

	local function runLoop()
		while not self.destroyed do
			local dt = RunService.Heartbeat:Wait()
			if self.destroyed then break end

			local nextCurrent, currentDone = stepBar(self.currentGradient, self.currentDisplayed, self.currentTarget, CURRENT_RATE, dt)
			self.currentDisplayed = nextCurrent

			local nextGrey, greyDone = stepBar(self.greyGradient, self.greyDisplayed, self.greyTarget, GREY_RATE, dt)
			self.greyDisplayed = nextGrey

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
		if self.lerpThread and coroutine.status(self.lerpThread) ~= "dead" then return end
		self.lerpThread = task.spawn(runLoop)
	end

	self.healthChangedConn = damageable.HealthChanged:Connect(function(newHP, oldHP)
		if self.destroyed then return end
		local fraction = math.clamp(newHP / damageable.MaxHP, 0, 1)

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

		self.currentTarget = fraction
		self.greyTarget = fraction
		ensureLoop()
	end)

	self.diedConn = damageable.Died:Connect(function() self:Destroy() end)
	self.destroyedConn = damageable.Destroyed:Connect(function() self:Destroy() end)

	return self
end

function HealthGui:Destroy()
	local s = self :: any
	if s.destroyed then return end
	s.destroyed = true
	s.healthChangedConn:Disconnect()
	s.diedConn:Disconnect()
	s.destroyedConn:Disconnect()
end

return HealthGui
