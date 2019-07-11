module VitaminOptimizer

import JSON, GLPK
using JuMP, LinearAlgebra

include("parseConstraints.jl")
include("parseMotorOptions.jl")
include("featureMatrix.jl")

const gravity = 9.80665

"""
	optimalIndices(slots)

Find the indices of the chosen values of `slots` (the indices where `slots[i] == 1`).
"""
optimalIndices(slots) = [findfirst(isequal(1), value.(slot)) for slot in slots]

"""
	optimalColumns(featureMatrix, slots)

Get the columns of the `featureMatrix` corresponding to the chosen values for the `slots`.
"""
optimalColumns(featureMatrix, slots) = [featureMatrix[:, i] for i in optimalIndices(slots)]

"""
	findMotorIndex(featureMatrixColumn, motors)

Find the index of the motor in the `motors` array by searching for a motor with τStall, ωFree, price,
and mass equal to those in the `featureMatrixColumn` (after un-applying the gear ratio).
"""
findMotorIndex(featureMatrixColumn, motors) = findfirst(
	# Approximate equality on τStall and ωFree because we are un-applying the gear ratio.
	x::Motor -> x.τStall ≈ featureMatrixColumn[1] * featureMatrixColumn[6] &&
		x.ωFree ≈ featureMatrixColumn[2] / featureMatrixColumn[6] &&
		x.price == featureMatrixColumn[3] &&
		x.mass == featureMatrixColumn[4],
	motors)

"""
	findOptimalMotors(featureMatrix, allSlots, motors)

Find the optimal motors after the most recent optimization.
"""
findOptimalMotors(featureMatrix, allSlots, motors) =
	hcat([(motors[findMotorIndex(col, motors)], col[6]) for col in optimalColumns(featureMatrix, allSlots)]...)

"""
	exploreParetoFrontier(model::Model, optimalObjectiveValue, featureMatrix, allSlots, motors)

Iteratively optimize the `model` to find all solutions at a given `optimalObjectiveValue` by adding a
constraint to disallow the most recent combination of slot values. Returns an array of all solutions.
"""
function exploreParetoFrontier(model::Model, optimalObjectiveValue, featureMatrix, allSlots, motors)
	# Disallow the current solution by disallowing the combination of the current slot1, slot2, and slot3
	# values.
	@constraint(model, sum(x -> x[1][x[2]], zip(allSlots, optimalIndices(allSlots))) <= length(allSlots) - 1)

	# Optimize again to find a different solution.
	optimize!(model)

	# If we are no longer at the given optimum or if the model failed to opimize, stop.
	if objective_value(model) != optimalObjectiveValue || failedToOptimize(model)
		return []
	else
		# Record the current solution.
		solution = findOptimalMotors(featureMatrix, allSlots, motors)
		printOptimizationResult!(model, solution)

		# Keep finding more solutions.
		otherSolutions = exploreParetoFrontier(model, optimalObjectiveValue, featureMatrix, allSlots, motors)

		# Add the current solution to the end of the other solutions.
		if otherSolutions == []
			return solution
		else
			return vcat(solution, otherSolutions)
		end
	end
end

"""
	optimizeAtParetoFrontier(model::Model, optimalObjectiveValue, objectiveFunction, featureMatrix, allSlots, motors)

Further optimize the `model` at the Pareto frontier defined by `optimalObjectiveValue`. This function
is invalid for values of `optimalObjectiveValue` which are not actually optimal.
"""
function optimizeAtParetoFrontier(model::Model, optimalObjectiveValue, objectiveFunction, featureMatrix, allSlots, motors)
	# Force the model to stay at the Pareto frontier.
	@constraint(model, objectiveFunction <= optimalObjectiveValue)

	numRows, numCols = size(featureMatrix)
	featureIdentity = Matrix{Float64}(I, numRows, numRows)
	gearRatioRow = transpose(featureIdentity[6,:])
	slotGearRatio(i) = gearRatioRow * featureMatrix * allSlots[i]
	@objective(model, Max, sum(i -> slotGearRatio(i), 1:length(allSlots)))

	optimize!(model)

	if failedToOptimize(model)
		error("Failed to opimize the model at the Pareto frontier.")
	else
		return findOptimalMotors(featureMatrix, allSlots, motors)
	end
end

"""
	failedToOptimize(model)

Check if the `model` failed to optimize.
"""
failedToOptimize(model) = !(termination_status(model) == MOI.OPTIMAL ||
	(termination_status(model) == MOI.TIME_LIMIT && has_values(model)))

onlyOneSelection(model, slot) = @constraint(model, sum(slot) == 1)

"""
	buildAndOptimizeModel!(model, limb, motors, gearRatios)

Add the initial variables and constraints to the `model` using a feature matrix
built from `limb`, and the coproduct of `motors` and `gearRatios`. Optimize the
model to minimize price using the optimizer in the `model`.
"""
function buildAndOptimizeModel!(model::Model, limb::Limb, motors, gearRatios)
	limbConfig = limb.minLinks

	# Each slot is a binary vector with a 1 that picks which motor to use.
	numFmCols = length(motors) * length(gearRatios)
	@variable(model, slot1[1:numFmCols], Bin)
	@variable(model, slot2[1:numFmCols], Bin)
	@variable(model, slot3[1:numFmCols], Bin)

	motorSlots = [slot1, slot2, slot3]
	for slot in motorSlots
		onlyOneSelection(model, slot)
	end

    Fm = FeatureMatrix(constructMotorFeatureMatrix(motors, gearRatios), motorSlots)
	@addSlotFunc(Fm, slotτ, 1)
	@addSlotFunc(Fm, slotω, 2)
	@addSlotFunc(Fm, slotPrice, 3)
	@addSlotFunc(Fm, slotMass, 4)
	@addSlotFunc(Fm, slotOmegaFunc, 5)
	@addSlotFunc(Fm, slotGearRatio, 6)

	# link1Row = transpose(featureIdentity[7,:])
	# slotLink1(i) = link1Row * F_m * allSlots[i]
	#
	# link2Row = transpose(featureIdentity[8,:])
	# slotLink2(i) = link2Row * F_m * allSlots[i]
	#
	# link3Row = transpose(featureIdentity[9,:])
	# slotLink3(i) = link3Row * F_m * allSlots[i]
	#
	# massTimesLink1Row = transpose(featureIdentity[10,:])
	# slotMassTimesLink1(i) = massTimesLink1Row * F_m * allSlots[i]
	#
	# massTimesLink2Row = transpose(featureIdentity[11,:])
	# slotMassTimesLink2(i) = massTimesLink2Row * F_m * allSlots[i]

	# Equation 3
	@expression(model, τ1Required, limb.tipForce * (limbConfig[1].dhParam.r + limbConfig[2].dhParam.r +
	 							   		limbConfig[3].dhParam.r) +
								   gravity * (slotMass(2) * limbConfig[1].dhParam.r +
								   slotMass(3) * (limbConfig[1].dhParam.r + limbConfig[2].dhParam.r)))

    # # TODO: I think I need a separate link feature matrix
   	# @expression(model, τ1Required, limb.tipForce * (slotLink1(1) + limbConfig[2].dhParam.r +
   	#  							   		limbConfig[3].dhParam.r) +
   	# 							   gravity * (slotMass(2) * limbConfig[1].dhParam.r +
   	# 							   slotMass(3) * (limbConfig[1].dhParam.r + limbConfig[2].dhParam.r)))

	@constraint(model, eq3, slotτ(1) .>= τ1Required)

	# Equation 4
	@expression(model, τ2Required, limb.tipForce * (limbConfig[2].dhParam.r + limbConfig[3].dhParam.r) +
								   slotMass(3) * gravity * limbConfig[2].dhParam.r)
	@constraint(model, eq4, slotτ(2) .>= τ2Required)

	# Equation 5
	@expression(model, τ3Required, limb.tipForce * limbConfig[3].dhParam.r)
	@constraint(model, eq5, slotτ(3) .>= τ3Required)

	# Equation 6
	@expression(model, ω1Required, limb.tipVelocity / (limbConfig[1].dhParam.r + limbConfig[2].dhParam.r +
	 									limbConfig[3].dhParam.r))
	@constraint(model, eq6, slotω(1) .>= ω1Required)

	# Equation 7
	@expression(model, ω2Required, limb.tipVelocity / (limbConfig[2].dhParam.r + limbConfig[3].dhParam.r))
	@constraint(model, eq7, slotω(2) .>= ω2Required)

	# Equation 8
	@expression(model, ω3Required, limb.tipVelocity / limbConfig[3].dhParam.r)
	@constraint(model, eq8, slotω(3) .>= ω3Required)

	objectiveFunction = sum(i -> slotPrice(i), 1:length(motorSlots))
	@objective(model, Min, objectiveFunction)

	# Run the first optimization pass.
	optimize!(model)

	if failedToOptimize(model)
		error("The model was not solved correctly.")
	else
		# Get the first solution and use it to find the other solutions.
		solution = findOptimalMotors(Fm.matrix, motorSlots, motors)

		println("Found solution:")
		printOptimizationResult!(model, solution)

		return (model, objectiveFunction, solution, Fm.matrix, motorSlots)
	end
end

function makeGLPKModel()::Model
	return Model(with_optimizer(GLPK.Optimizer))
end

function printOptimizationResult!(model, optimalMotors)
	if termination_status(model) == MOI.TIME_LIMIT
		println("-------------------------------------------------------")
		println("-------------------SUBOPTIMAL RESULT-------------------")
		println("-------------------------------------------------------")
	end

	println("Optimal objective: ", objective_value(model))
	println("Optimal motors:")
	for (mtr, ratio) in optimalMotors
		println("\t", mtr, ", ratio=", ratio)
	end
end

"""
	loadProblem(constraintsFile::String, limbName::String, motorOptionsFile::String)

Load the constraints from `constraintsFile` and the motor options from
`motorOptionsFile`. Select limb `limbName` from the constraints.
"""
function loadProblem(constraintsFile::String, limbName::String, motorOptionsFile::String)
	limb = parseConstraints!(constraintsFile, [limbName])[1]
	motors = parseMotorOptions!(motorOptionsFile)

	# TODO: Put available gear ratios in the constraints file
	ratios = collect(range(1, step=2, length=30))
	gearRatios = Set(hcat(ratios, 1 ./ ratios))

	return (limb, motors, gearRatios)
end

"""
	loadAndOptimize!(model::Model, constraintsFile::String, limbName::String, motorOptionsFile::String)

Load the constraints from `constraintsFile` and the motor options from
`motorOptionsFile`. Select limb `limbName` from the constraints. Uses the
optimizer in the `model`. Returns the Pareto set.

# Examples
```jldoctest
julia> loadAndOptimize!("res/constraints1.json", "HephaestusArmLimbOne", "res/motorOptions.json")
Optimal objective: 38.849999999999994
Optimal motors:
    VitaminOptimizer.Motor("stepperMotor-GenericNEMA14", 0.098, 139.626, 12.95, 0.12), ratio=0.021
    VitaminOptimizer.Motor("stepperMotor-GenericNEMA14", 0.098, 139.626, 12.95, 0.12), ratio=0.048
    VitaminOptimizer.Motor("stepperMotor-GenericNEMA14", 0.098, 139.626, 12.95, 0.12), ratio=0.077
```
"""
function loadAndOptimize!(model::Model, constraintsFile::String, limbName::String, motorOptionsFile::String)
	limb, motors, gearRatios = loadProblem(constraintsFile, limbName, motorOptionsFile)

	println("Optimizing initial model.")
	model, objectiveFunction, solution, featureMatrix, allSlots = buildAndOptimizeModel!(model, limb, motors, gearRatios)

	println("Exploring Pareto frontier.")
	otherSolutions = exploreParetoFrontier(model, objective_value(model), featureMatrix, allSlots, motors)

	printOptimizationResult!(model, solution)
	return vcat(solution, otherSolutions)
end

"""
	loadAndOptimzeAtParetoFrontier!(model::Model, constraintsFile::String, limbName::String, motorOptionsFile::String)

Load the constraints from `constraintsFile` and the motor options from
`motorOptionsFile`. Select limb `limbName` from the constraints. Uses the
optimizer in the `model`. Optimizes the model once, assumes the objective value from that optimization
is in the Pareto set, and then optimizes again inside the Pareto set. Returns the optimal value from the
second round of optimization.

# Examples
```jldoctest
julia> loadAndOptimize!("res/constraints1.json", "HephaestusArmLimbOne", "res/motorOptions.json")
Optimal objective: 38.849999999999994
Optimal motors:
    VitaminOptimizer.Motor("stepperMotor-GenericNEMA14", 0.098, 139.626, 12.95, 0.12), ratio=0.047619
    VitaminOptimizer.Motor("stepperMotor-GenericNEMA14", 0.098, 139.626, 12.95, 0.12), ratio=0.047619
    VitaminOptimizer.Motor("stepperMotor-GenericNEMA14", 0.098, 139.626, 12.95, 0.12), ratio=0.111111
```
"""
function loadAndOptimzeAtParetoFrontier!(model::Model, constraintsFile::String, limbName::String, motorOptionsFile::String)
	limb, motors, gearRatios = loadProblem(constraintsFile, limbName, motorOptionsFile)

	println("Optimizing initial model.")
	model, objectiveFunction, solution, featureMatrix, allSlots = buildAndOptimizeModel!(model, limb, motors, gearRatios)

	println("Optimizing at Pareto frontier.")
	solution =  optimizeAtParetoFrontier(model, objective_value(model), objectiveFunction, featureMatrix, allSlots, motors)

	printOptimizationResult!(model, solution)
	return solution
end

export loadAndOptimize!
export loadAndOptimzeAtParetoFrontier!
export makeGLPKModel
export printOptimizationResult!

loadAndOptimize!(
	makeGLPKModel(),
	"res/constraints1.json",
	"HephaestusArmLimbOne",
	"res/motorOptions.json"
)

end # module VitaminOptimizer
