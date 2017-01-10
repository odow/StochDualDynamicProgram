#  Copyright 2017, Oscar Dowson

"""
    This function assembles a new cut using the following inputs
    + measure::AbstractRiskMeasure - used to dispatch
    + sense::Sense - either Maximum or Minimum
    + x::Vector{Vector{Float64}} - a vector of vector of state values for each scenario
    + pi::Vector{Vector{Float64}} - a vector of vector of dual values for each scenario
    + theta::Vector{Float64} - a vector of objective values for each scenario
    + prob::Vector{Float64} - the probability support of the scenarios. Should sum to one
    + stage::Int - the index of the stage
    + markov::Int - the index of the markov state
"""
cutgenerator(measure::AbstractRiskMeasure, sense::Sense, x, pi, theta, prob, stage, markov) =
    cutgenerator(measure::AbstractRiskMeasure, sense::Sense, x, pi, theta, prob)

cutgenerator(measure::AbstractRiskMeasure, sense::Sense, x, pi, theta, prob) = error("""
    You need to overload a `cutgenerator` method for the measure of type $(typeof(measure)).
    This could be the method including the stage and markov index
        cutgenerator(measure::AbstractRiskMeasure, sense::Sense, x, pi, theta, prob, stage, markov)
    or
        cutgenerator(measure::AbstractRiskMeasure, sense::Sense, x, pi, theta, prob)
""")


"""
    Normal old expectation
"""
immutable Expectation <: AbstractRiskMeasure end

function cutgenerator(ex::Expectation, sense::Sense, x, pi, theta, prob)
    @assert length(pi) == length(theta) == length(prob)
    intercept = (theta[1] - dot(pi[1], x))*prob[1]
    coefficients = pi[1] * prob[1]
    @inbounds for i=2:length(prob)
        intercept += (theta[i] - dot(pi[i], x))*prob[i]
        coefficients += pi[i] * prob[i]
    end
    return Cut(intercept, coefficients)
end

# λ * E[x] + (1 - λ) * CVaR(β)[x]
const expectation = Expectation()
_sortperm(::Type{Maximisation}, x) = sortperm(x, rev=false)
_sortperm(::Type{Minimisation}, x) = sortperm(x, rev=true)
function calculateCVaRprobabilities!(newprob, sense, oldprob, theta, lambda, beta::Float64)
    @assert length(newprob) >= length(oldprob)
    quantile_collected = 0.0
    cvarprob = 0.0
    cache = (1 - lambda) / beta                # cache this to save some operations
    @inbounds for i in _sortperm(sense, theta) # For each scenario in order
        newprob[i] = lambda * oldprob[i]       # expectation contribution
        if quantile_collected <  beta          # We haven't collected the beta quantile
            cvarprob = min(oldprob[i], beta-quantile_collected)
            newprob[i] += cache * cvarprob     # risk averse contribution
            quantile_collected += cvarprob     # Update total quantile collected
        end
    end
end

"""
    Nested CV@R
        λE[x] + (1-λ)CV@R(1-α)(x)
"""
immutable NestedCVaR <: AbstractRiskMeasure
    beta::Float64
    lambda::Float64
    storage::Vector{Float64}
end
function checkzerotoone(x)
    @assert x <= 1
    @assert x >= 0
end
function NestedCVaR(beta, lambda)
    checkzerotoone(beta)
    checkzerotoone(lambda)
    NestedCVaR(beta, lambda, Float64[])
end
NestedCVaR(;beta=1, lambda=1) = NestedCVaR(beta, lambda)

function cutgenerator(cvar::NestedCVaR, sense::Sense, x, pi, theta, prob)
    @assert length(pi) == length(theta) == length(prob)
    if length(cvar.storage) < length(prob)
        append!(cvar.storage, zeros(length(prob) - length(cvar.storage)))
    end
    calculateCVaRprobabilities!(cvar.storage, sense, prob, theta, cvar.lambda, cvar.beta)

    cutgenerator(expectation, sense, x, pi, theta, view(cvar.storage, 1:length(prob)))
end
