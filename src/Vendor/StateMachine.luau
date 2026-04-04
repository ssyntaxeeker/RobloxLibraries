--[[
My attempt at a reusable state machine. 

- sol (3693744006)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)

type BaseState<T, C> = {
	id: T,
	EnterState: (context: C) -> (),
	ExitState: (context: C) -> (),
	UpdateState: (context: C, dt: number) -> (),
	GetNextState: (context: C) -> T?,
}

type Machine<T, C> = {
	Update: (self: Machine<T, C>, dt: number) -> (),
	SetState: (self: Machine<T, C>, next: T) -> (),
	GetState: (self: Machine<T, C>) -> T,

	OnEnter: any,
	OnStay: any,
	OnExit: any,
}

type MachineInternal<T, C> = Machine<T, C> & {
	_states: { [T]: BaseState<T, C> },
	_current: BaseState<T, C>,
	_context: C,
}

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new<T, C>(initial: T, states: { [T]: BaseState<T, C> }, context: C): Machine<T, C>
	local self = setmetatable({}, StateMachine) :: any
	local machine = self :: MachineInternal<T, C>

	machine._states = states
	machine._context = context
	machine._current = states[initial]

	machine.OnEnter = Signal.new()
	machine.OnStay = Signal.new()
	machine.OnExit = Signal.new()

	machine._current.EnterState(machine._context)
	machine.OnEnter:Fire(machine._current.id)

	return machine
end

function StateMachine:Update(dt: number)
	local current = self._current
	local next = current.GetNextState(self._context)

	if next and next ~= current.id then
		self:SetState(next)
		return
	end

	current.UpdateState(self._context, dt)
	self.OnStay:Fire(current.id, dt)
end

function StateMachine:SetState(next)
	local current = self._current
	local newState = self._states[next]

	if not newState then return end

	current.ExitState(self._context)
	self.OnExit:Fire(current.id)

	self._current = newState

	newState.EnterState(self._context)
	self.OnEnter:Fire(newState.id)
end

function StateMachine:GetState()
	return self._current.id
end

return StateMachine
