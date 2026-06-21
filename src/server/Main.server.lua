--!strict

local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ServerStorage:WaitForChild("Shared")
local Damageable = require(Shared:WaitForChild("Damageable"))
local HealthGui = require(Shared:WaitForChild("HealthGui"))

local MAX_HP = 100
local TICK_MIN = 0.3
local TICK_MAX = 1.2
local DAMAGE_MIN = 3
local DAMAGE_MAX = 18
local RESPAWN_DELAY = 1.0

local function waitForChildOfClass(parent: Instance, className: string): Instance
	local existing = parent:FindFirstChildOfClass(className)
	if existing then return existing end
	while true do
		local child = parent.ChildAdded:Wait()
		if child:IsA(className) then return child end
	end
end

local part = Workspace:WaitForChild("HealthBar") :: BasePart
local billboard = waitForChildOfClass(part, "BillboardGui") :: BillboardGui

local function spawnEntity()
	local entity = Damageable.new(part, MAX_HP)
	HealthGui.new(entity, billboard)

	local diedConn
	diedConn = entity.Died:Connect(function()
		if diedConn then diedConn:Disconnect() end
		task.wait(RESPAWN_DELAY)
		entity:Destroy()
		spawnEntity()
	end)

	task.spawn(function()
		while entity:IsAlive() do
			task.wait(TICK_MIN + math.random() * (TICK_MAX - TICK_MIN))
			if not entity:IsAlive() then break end
			local dmg = math.random(DAMAGE_MIN, DAMAGE_MAX)
			entity:ApplyDamage(dmg)
			print(("Dealt %d damage. HP: %d/%d"):format(dmg, entity.CurrentHP, entity.MaxHP))
		end
	end)
end

spawnEntity()
