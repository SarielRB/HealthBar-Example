--!strict

local Damageable = {}
Damageable.__index = Damageable

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

local function newSignal(): Signal
	local handlers: { Handler } = {}
	local signal = {} :: any

	function signal:Connect(handler: Handler): Connection
		table.insert(handlers, handler)
		local conn = { Connected = true } :: Connection
		function conn:Disconnect()
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

function Damageable.new(instance: Instance, maxHP: number): Damageable
	assert(maxHP > 0, "maxHP must be > 0")

	local self: any = setmetatable({
		Instance = instance,
		MaxHP = maxHP,
		CurrentHP = maxHP,
		HealthChanged = newSignal(),
		Died = newSignal(),
		Destroyed = newSignal(),
		_alive = true,
		_destroyed = false,
	}, Damageable)
	return self
end

function Damageable:ApplyDamage(amount: number, source: Instance?): number
	local s = self :: any
	if not s._alive or amount <= 0 then return 0 end

	local before = s.CurrentHP
	local after = math.max(before - amount, 0)
	s.CurrentHP = after
	s.HealthChanged:Fire(after, before)

	if after == 0 then
		s._alive = false
		s.Died:Fire(source)
	end

	return before - after
end

function Damageable:Heal(amount: number): number
	local s = self :: any
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
	s.Destroyed:Fire()
	s.HealthChanged:DisconnectAll()
	s.Died:DisconnectAll()
	s.Destroyed:DisconnectAll()
end

return Damageable
