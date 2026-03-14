--!strict

--[[
	DecayMeter

	A high-performance decay meter system designed for large-scale gameplay systems.
	This module allows you to create many independent meters whose values increase
	and then decay over time after a configurable delay.

	The system is heavily optimized using data-oriented design principles:
	- Structure-of-arrays storage layout
	- Sparse active meter iteration
	- Time-bucket delay scheduling
	- Swap-pop active list removal
	- Free-list ID recycling
	- Automatic update loop suspension

	Meters that are waiting for their delay to expire also incur zero per-frame cost.

	This makes the module suitable for extremely large systems such as:
	- Camera trauma meters
	- AI alertness systems
	- Sanity / fear mechanics
	- Combat stress tracking
	- Cooldown decay mechanics

	Author: sol (3693744006)
	Version: 14-03-26 (1)
]]

local RunService = game:GetService("RunService")

local DecayMeter = {}

-- Types
export type MeterId = number

export type Config = {
	max: number?,
	decayRate: number?,
	decayDelay: number?,
	cleanupOnDeplete: boolean?,
	onChanged: ((MeterId, number) -> ())?,
	onDepleted: ((MeterId) -> ())?,
}

-- Constants
local FLAG_CLEANUP_ON_DEPLETION = 1

local BUCKET_GRANULARITY = 0.1
local BUCKET_INV = 1 / BUCKET_GRANULARITY

-- Storage
local values: { number? } = table.create(256)
local maxValues: { number? } = table.create(256)

local decayRates: { number? } = table.create(256)
local decayDelays: { number? } = table.create(256)

local flags: { number? } = table.create(256)

local changedCallbacks: { ((MeterId, number) -> ())? } = table.create(256)
local depletedCallbacks: { ((MeterId) -> ())? } = table.create(256)

local alive: { boolean? } = table.create(256)

-- Active meter tracking
local activeMeters: { MeterId? } = table.create(256)
local activeIndex: { [MeterId]: number? } = {}

local activeCount = 0

-- Delay scheduling buckets
local delayBuckets: { [number]: { MeterId } } = {}

-- ID allocation
local recycledIds: { MeterId } = table.create(256)
local meterCount = 0

-- Loop state
local running = false
local connection: RBXScriptConnection? = nil

--[[
    Allocates meter ID.
    
]]
local function allocateId(): MeterId
	local reused = table.remove(recycledIds)

	if reused then return reused end

	meterCount += 1
	return meterCount
end

--[[
    Recycles meter ID.
    
    @param id ID of the meter to recycle.
]]
local function recycleId(id: MeterId)
	table.insert(recycledIds, id)
end

--[[
    Activates meter.

    @param id ID of the meter to activate.
]]
local function activate(id: MeterId)
	if activeIndex[id] ~= nil then return end

	activeCount += 1
	activeMeters[activeCount] = id
	activeIndex[id] = activeCount
end

--[[
    Deactivates meter.

    @param id ID of the meter to deactivate.
]]
local function deactivate(id: MeterId)
	local index = activeIndex[id]
	if not index then return end

	local lastId = activeMeters[activeCount]

	activeMeters[index] = lastId
	activeIndex[lastId :: MeterId] = index

	activeMeters[activeCount] = nil
	activeIndex[id] = nil

	activeCount -= 1
end

--[[
    Schedules delayed decay.

    @param id ID of the meter to schedule.
    @param delay The delay in seconds.
]]
local function scheduleDelay(id: MeterId, delay: number)
	local wakeTime = os.clock() + delay
	local bucketId = math.floor(wakeTime * BUCKET_INV)

	local bucket = delayBuckets[bucketId]

	if bucket then
		bucket[#bucket + 1] = id
	else
		delayBuckets[bucketId] = { id }
	end
end

--[[
    Updates loop. 

    @param dt Delta time.
]]
local function update(dt: number)
	local now = os.clock()
	local currentBucket = math.floor(now * BUCKET_INV)

	local bucket = delayBuckets[currentBucket]

	if bucket then
		for i = 1, #bucket do
			local meterId = bucket[i]

			if alive[meterId] then activate(meterId) end
		end

		delayBuckets[currentBucket] = nil
	end

	local meters = activeMeters

	local meterValues = values
	local meterDecayRates = decayRates

	local meterFlags = flags

	local changeFns = changedCallbacks
	local depletedFns = depletedCallbacks

	local index = 1

	while index <= activeCount do
		local meterId = meters[index] :: MeterId

		local newValue = (meterValues[meterId] :: number) - (meterDecayRates[meterId] :: number) * dt

		if newValue <= 0 then
			meterValues[meterId] = 0

			local depleted = depletedFns[meterId]
			if depleted then depleted(meterId) end

			if bit32.band(meterFlags[meterId] or 0, FLAG_CLEANUP_ON_DEPLETION) ~= 0 then
				DecayMeter.Destroy(meterId)
				continue
			end

			deactivate(meterId)
		else
			meterValues[meterId] = newValue

			local changed = changeFns[meterId]
			if changed then changed(meterId, newValue) end
		end

		index += 1
	end

	if activeCount == 0 and next(delayBuckets) == nil then
		running = false

		if connection then
			connection:Disconnect()
			connection = nil
		end
	end
end

--[[
    Ensures the loop is running. 

]]
local function ensureLoop()
	if running then return end

	running = true
	connection = RunService.Heartbeat:Connect(update)
end

--[[
	Creates a new decay meter.

	@param config Configuration table controlling meter behavior.
	@return MeterId Unique identifier for the created meter.

	Example:

	local id = DecayMeter.Create({
		max = 100,
		decayRate = 20,
		decayDelay = 2
	})
]]
function DecayMeter.Create(config: Config): MeterId
	local id = allocateId()

	alive[id] = true

	values[id] = 0
	maxValues[id] = config.max or 1

	decayRates[id] = config.decayRate or 1
	decayDelays[id] = config.decayDelay or 0

	flags[id] = config.cleanupOnDeplete and FLAG_CLEANUP_ON_DEPLETION or 0

	changedCallbacks[id] = config.onChanged
	depletedCallbacks[id] = config.onDepleted

	return id
end

--[[
	Adds value to a meter.

	The meter will begin decaying after its configured delay.

	@param id Meter identifier.
	@param amount Amount to add to the meter.
]]
function DecayMeter.Add(id: MeterId, amount: number)
	if not alive[id] then return end

	local newValue = (values[id] :: number) + amount
	local maxValue = maxValues[id] :: number

	if newValue > maxValue then newValue = maxValue end

	values[id] = newValue

	local delay = decayDelays[id] :: number

	if delay > 0 then
		scheduleDelay(id, delay)
	else
		activate(id)
	end

	ensureLoop()

	local changed = changedCallbacks[id]
	if changed then changed(id, newValue) end
end

--[[
	Sets the meter value directly.

	@param id Meter identifier.
	@param value New meter value.
]]
function DecayMeter.Set(id: MeterId, value: number)
	if not alive[id] then return end

	local maxValue = maxValues[id] :: number

	if value > maxValue then
		value = maxValue
	elseif value < 0 then
		value = 0
	end

	values[id] = value

	if value > 0 then
		local delay = decayDelays[id] :: number

		if delay > 0 then
			scheduleDelay(id, delay)
		else
			activate(id)
		end

		ensureLoop()
	end

	local changed = changedCallbacks[id]
	if changed then changed(id, value) end
end

--[[
	Returns the current meter value.

	@param id Meter identifier.
	@return Current value of the meter.
]]
function DecayMeter.Get(id: MeterId): number
	return values[id] or 0
end

--[[
	Returns the meter value normalized between 0 and 1.

	@param id Meter identifier.
	@return Normalized meter value.
]]
function DecayMeter.GetNormalized(id: MeterId): number
	return (values[id] or 0) / (maxValues[id] or 1)
end

--[[
	Destroys a meter and releases its internal resources.

	@param id Meter identifier.
]]
function DecayMeter.Destroy(id: MeterId)
	if not alive[id] then return end

	alive[id] = nil

	deactivate(id)

	values[id] = nil
	maxValues[id] = nil

	decayRates[id] = nil
	decayDelays[id] = nil

	flags[id] = nil

	changedCallbacks[id] = nil
	depletedCallbacks[id] = nil

	recycleId(id)
end

return DecayMeter
