const SIGMA_IN_MM = 7
const DEBUG_PATH = "F:/MRI/Analysis/debug_hom"

# make other input types possible
makehomogeneous(mag::NIVolume, datatype = eltype(mag); keyargs...) = makehomogeneous!(datatype.(mag); pixdim = mag.header.pixdim[2:(1+ndims(mag))], keyargs...)
makehomogeneous(mag, datatype = eltype(mag); keyargs...) = makehomogeneous!(datatype.(mag); keyargs...)


# split sigma in two parts
function getsigma(pixdim)
    factorfinalsmoothing = 0.7
    σ = SIGMA_IN_MM ./ pixdim
    σ1 = sqrt(1 - factorfinalsmoothing^2) .* σ
    σ2 = factorfinalsmoothing .* σ
    return σ1, σ2
end

getsensitivity(mag::NIVolume; keyargs...) = getsensitivity(mag; pixdim = mag.header.pixdim[2:(1+ndims(mag))], keyargs...)
function getsensitivity(mag; pixdim, maxiteration = 1)
    σ1, σ2 = getsigma(pixdim)
    firstecho = view(mag,:,:,:,1)

    @debug savenii(mag, "mag", DEBUG_PATH)
    mask = robustmask(firstecho)
    @debug savenii(mask, "mask", DEBUG_PATH)
    lowpass = gaussiansmooth3d(firstecho, σ1 .+ σ2; mask = mask)
    @debug savenii(lowpass, "lowpass", DEBUG_PATH)
    segmentation = boxsegment(firstecho ./ lowpass, mask)
    @debug savenii(segmentation, "segmentation", DEBUG_PATH)
    lowpass = iterative(firstecho, mask, segmentation, σ1, maxiteration)
    @debug savenii(lowpass, "lowpass_after_it", DEBUG_PATH)
    fillandsmooth!(lowpass, mean(firstecho[mask]), σ2)
    @debug savenii(lowpass, "lowpass_after_fillsmooth", DEBUG_PATH)

    return lowpass
end

function makehomogeneous!(mag; keyargs...)
    lowpass = getsensitivity(mag; keyargs...)
    if eltype(mag) <: AbstractFloat
        mag ./= lowpass
    else # Integer
        lowpass[isnan.(lowpass) .| (lowpass .<= 0)] .= typemax(eltype(lowpass))
        mag .= div.(mag, lowpass ./ 2048) .|> x -> min(x, typemax(eltype(mag)))
    end
    mag
end

function fillandsmooth!(lowpass, stablemean, σ2)
    stablethresh = stablemean / 4
    lowpassmask = (lowpass .< stablethresh) .| isnan.(lowpass) .| (lowpass .> 10 * stablemean)
    lowpass[lowpassmask] .= 3 * stablemean
    lowpassweight = 1.2 .- lowpassmask
    gaussiansmooth3d!(lowpass, σ2; weight = lowpassweight)
end

function threshold(image, mask; lowthresh = 0.95)
    # TODO masked = image[mask .& .!(insan.(masked))]
    masked = image[mask]
    masked[isnan.(masked)] .= 0

    m = mean(masked)
    try
        m = median(masked[(masked .> 0.9m) .& (masked .< 2m)]) # TODO compare timing and stability with mean
    catch ex
        m = 0
    end

    (lowthresh*m .< image .< 1.1m) .& mask
end

threshold(image) = threshold(image, robustmask(image))

function iterative(firstecho, mask, segmentation, sigma, maxiteration)
    local lowpass
    local wm_mask = segmentation
    for i in 1:maxiteration
        lowpass = gaussiansmooth3d(firstecho, sigma; mask = wm_mask, nbox = 8)
        @debug savenii(lowpass, "lowpass_$i", DEBUG_PATH)
        highpass = firstecho ./ lowpass
        highpass[.!isfinite.(highpass)] .= 0
        @debug savenii(highpass, "highpass_$i", DEBUG_PATH)

        new_mask = threshold(highpass, mask; lowthresh = 0.99)
        @debug savenii(new_mask, "new_mask_$i", DEBUG_PATH)

        if i > 1
            change = sum(new_mask .!= wm_mask) / sum(new_mask)
            if change < 0.02 break end
            if change > 1 break end
        end
        wm_mask = new_mask
    end
    lowpass
end

function boxsegment!(image::AbstractArray{T}, mask; nboxes = 15) where T <: AbstractFloat
    image[boxsegment(image, mask; nboxes = nboxes)] .= NaN
    image
end

# TODO check if inside box is only noise -> no pre mask required (std < 2 * mean ?)
function boxsegment(image, mask; nboxes = 15)
    N = size(image)
    dim = ndims(image)
    boxsize = max.(20, round.(Int, N ./ nboxes))
    boxshift = ceil.(Int, boxsize ./ 2)

    segmented = copy(mask) #TODO: sure this is a good initialization value?
    for t in Iterators.product([1:boxshift[i]:N[i] for i in 1:dim]...)
        I = CartesianIndices( ntuple(d -> t[d]:min(t[d] + boxsize[d] - 1, N[d]), dim) )
        # I is a box
        segmented[I] = segmented[I] .& threshold(image[I], mask[I])
    end
    segmented
end
