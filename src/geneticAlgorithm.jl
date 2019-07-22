include("parseConstraints.jl")
include("parseMotorOptions.jl")
include("featureMatrix.jl")

import LinearAlgebra

const gravity = 9.80665

"""
	loadProblem(constraintsFile::String, limbName::String, motorOptionsFile::String)

Load the constraints from `constraintsFile` and the motor options from
`motorOptionsFile`. Select limb `limbName` from the constraints.
"""
function loadProblem(constraintsFile::String, limbName::String, motorOptionsFile::String)
	limb = parseConstraints!(constraintsFile, [limbName])[1]
	motors = parseMotorOptions!(motorOptionsFile)

	# TODO: Put available gear ratios in the constraints file
	ratios = collect(range(1, step=2, length=10))
	gearRatios = Set(hcat(ratios, 1 ./ ratios))

	return (limb, motors, gearRatios)
end

struct Entity
	motor1Index::Int64
	motor2Index::Int64
	motor3Index::Int64
	link1Length::Int64
	link2Length::Int64
	link3Length::Int64
end

"""
Required functions:
	- GAFitness(entity)
	- GACrossover(entity1, entity2)
	- GAMutate(entity, mutationProb)
	- GAShouldStop(population)
"""
function geneticAlgorithm(initialPopulation::Vector{Entity}, constraints,
	crossoverProb::Int64, mutationProb::Int64, nElite::Int64, nCross::Int64)::Vector{Entity}
	popNum = length(initialPopulation)
	nMut = popNum - nElite - nCross
	population = initialPopulation

	@assert popNum > 0
	@assert nMut >= 0
	@assert 0 <= crossoverProb <= 100
	@assert 0 <= mutationProb <= 100

	while !GAShouldStop(population)
		# Step 2
		fitness = map(GAFitness, population)
		constraintValues = LinearAlgebra.normalize!(map(
			entity -> map(constraint -> constraint(entity), constraints),
			population))

		# Equation 13
		constraintViolationValues = map(
			valueList -> sum(x -> max(0, x), valueList),
			constraintValues)

		# Equation 14
		numberOfViolations = map(
			valueList -> sum(x -> x > 0, valueList) / length(constraints),
			constraintValues)

		function customLessThan(entity1::Entity, entity2::Entity)::Bool
			entity1Index = findfirst(isequal(entity1), population)
			entity2Index = findfirst(isequal(entity2), population)
			entity1Feasible = numberOfViolations[entity1Index] == 0
			entity2Feasible = numberOfViolations[entity2Index] == 0

			if entity1Feasible && entity2Feasible
				# Winner is the one with the highest fitness value
				return fitness[entity1Index] > fitness[entity2Index]
			end

			if xor(entity1Feasible, entity2Feasible)
				# Winner is the feasible one
				return entity1Feasible
			end

			# Both are infeasible
			if numberOfViolations[entity1Index] == numberOfViolations[entity2Index]
				# Winner is the one with the lowest CV
				return constraintViolationValues[entity1Index] < constraintViolationValues[entity2Index]
			else
				# Winner is the one with the lowest NV
				return numberOfViolations[entity1Index] < numberOfViolations[entity2Index]
			end
		end

		# Step 3
		sortedPopulation = sort(population, lt=customLessThan)

		# Step 4
		elites = sortedPopulation[1:nElite]

		# Step 5
		crossed = map(_ -> if (rand(1:100) <= crossoverProb) GACrossover(rand(elites), rand(elites)) else rand(elites) end, 1:nCross)
		mutated = map(_ -> GAMutate(rand(elites), mutationProb), 1:nMut)
		population = vcat(elites, crossed, mutated)
	end

	return population
end

global (limb, motors, gearRatios) = loadProblem(
	"res/constraints2.json",
	"HephaestusArmLimbOne",
	"res/motorOptions.json")

function GAFitness(entity::Entity)::Float64
	# Use negative of price because we maximize fitness
	return -1 * (motors[entity.motor1Index].price + motors[entity.motor2Index].price +
		motors[entity.motor3Index].price)
end

function GACrossover(entity1::Entity, entity2::Entity)::Entity
	# Take the motors from entity1 and the links from entity2
	return Entity(entity1.motor1Index, entity1.motor2Index, entity1.motor3Index,
		entity2.link1Length, entity2.link2Length, entity2.link3Length)
end

function GAMutate(entity::Entity, mutationProb::Int64)::Entity
	return Entity(
		if (rand(1:100) <= mutationProb) rand(1:length(motors)) else entity.motor1Index end,
		if (rand(1:100) <= mutationProb) rand(1:length(motors)) else entity.motor2Index end,
		if (rand(1:100) <= mutationProb) rand(1:length(motors)) else entity.motor3Index end,
		if (rand(1:100) <= mutationProb) rand(limb.minLinks[1].dhParam.r:limb.maxLinks[1].dhParam.r) else entity.link1Length end,
		if (rand(1:100) <= mutationProb) rand(limb.minLinks[2].dhParam.r:limb.maxLinks[2].dhParam.r) else entity.link2Length end,
		if (rand(1:100) <= mutationProb) rand(limb.minLinks[3].dhParam.r:limb.maxLinks[3].dhParam.r) else entity.link3Length end
	)
end

global generationNumber = 0
function GAShouldStop(population::Vector{Entity})::Bool
	global generationNumber += 1
	return generationNumber > 100
end

function makeRandomEntity()
	return GAMutate(Entity(0, 0, 0, 0, 0, 0), 100)
end

function makeConstraints()
	return [entity::Entity -> motors[entity.motor1Index].τStall -
				(limb.tipForce * (entity.link1Length + entity.link2Length + entity.link3Length) +
				gravity * (motors[entity.motor2Index].mass * entity.link1Length +
				motors[entity.motor3Index].mass * (entity.link1Length + entity.link2Length))),
		entity::Entity -> motors[entity.motor2Index].τStall -
				(limb.tipForce * (entity.link2Length + entity.link3Length) +
				motors[entity.motor3Index].mass * gravity * entity.link2Length),
		entity::Entity -> motors[entity.motor3Index].τStall - (limb.tipForce * entity.link3Length),
		entity::Entity -> motors[entity.motor1Index].ωFree - (limb.tipVelocity / (entity.link1Length + entity.link2Length + entity.link3Length)),
		entity::Entity -> motors[entity.motor2Index].ωFree - (limb.tipVelocity / (entity.link2Length + entity.link3Length)),
		entity::Entity -> motors[entity.motor3Index].ωFree - (limb.tipVelocity / entity.link3Length)]
end

global finalPopulation = geneticAlgorithm(
	map(x -> makeRandomEntity(), 1:10),
	makeConstraints(),
	40,
	5,
	2,
	3)

println(finalPopulation)
