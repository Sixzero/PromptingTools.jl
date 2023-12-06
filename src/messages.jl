# This file contains key building blocks of conversation history (messages) and utilities to work with them (eg, render)

## Messages
abstract type AbstractMessage end
abstract type AbstractChatMessage <: AbstractMessage end # with text-based content
abstract type AbstractDataMessage <: AbstractMessage end # with data-based content, eg, embeddings

## Allowed inputs for ai* functions, AITemplate is resolved one level higher
const ALLOWED_PROMPT_TYPE = Union{
    AbstractString,
    AbstractMessage,
    Vector{<:AbstractMessage},
}

# Workaround to be able to add metadata to serialized conversations, templates, etc.
# Ignored by `render` directives
Base.@kwdef struct MetadataMessage{T <: AbstractString} <: AbstractChatMessage
    content::T
    description::String = ""
    version::String = "1"
    source::String = ""
    _type::Symbol = :metadatamessage
end
Base.@kwdef struct SystemMessage{T <: AbstractString} <: AbstractChatMessage
    content::T
    variables::Vector{Symbol} = _extract_handlebar_variables(content)
    _type::Symbol = :systemmessage
end
Base.@kwdef struct UserMessage{T <: AbstractString} <: AbstractChatMessage
    content::T
    variables::Vector{Symbol} = _extract_handlebar_variables(content)
    _type::Symbol = :usermessage
end
Base.@kwdef struct UserMessageWithImages{T <: AbstractString} <: AbstractChatMessage
    content::T
    image_url::Vector{<:AbstractString} # no default! fail when not provided
    variables::Vector{Symbol} = _extract_handlebar_variables(content)
    _type::Symbol = :usermessagewithimages
end
Base.@kwdef struct AIMessage{T <: Union{AbstractString, Nothing}} <: AbstractChatMessage
    content::T = nothing
    status::Union{Int, Nothing} = nothing
    tokens::Tuple{Int, Int} = (-1, -1)
    elapsed::Float64 = -1.0
    _type::Symbol = :aimessage
end
Base.@kwdef struct DataMessage{T <: Any} <: AbstractDataMessage
    content::T
    status::Union{Int, Nothing} = nothing
    tokens::Tuple{Int, Int} = (-1, -1)
    elapsed::Float64 = -1.0
    _type::Symbol = :datamessage
end

# content-only constructor
function (MSG::Type{<:AbstractChatMessage})(prompt::AbstractString)
    MSG(; content = prompt)
end
isusermessage(m::AbstractMessage) = m isa UserMessage
issystemmessage(m::AbstractMessage) = m isa SystemMessage

# equality check for testing, only equal if all fields are equal and type is the same
Base.var"=="(m1::AbstractMessage, m2::AbstractMessage) = false
function Base.var"=="(m1::T, m2::T) where {T <: AbstractMessage}
    all([getproperty(m1, f) == getproperty(m2, f) for f in fieldnames(T)])
end
Base.length(t::AbstractMessage) = nfields(t)
function Base.iterate(t::AbstractMessage, iter = 1)
    iter > nfields(t) ? nothing : (getfield(t, iter), iter + 1)
end

## Vision Models -- Constructor and Conversion
"Construct `UserMessageWithImages` with 1 or more images. Images can be either URLs or local paths."
function UserMessageWithImages(prompt::AbstractString;
        image_url::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing,
        image_path::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing)
    @assert !(isnothing(image_url) && isnothing(image_path)) "At least one of `image_url` and `image_path` must be provided."
    url1 = !isnothing(image_url) ? _string_to_vector(image_url) : String[]
    # Process local image
    url2 = !isnothing(image_path) ? _string_to_vector(_encode_local_image(image_path)) :
           String[]
    return UserMessageWithImages(;
        content = prompt,
        image_url = vcat(url1, url2),
        variables = _extract_handlebar_variables(prompt),
        _type = :usermessagewithimage)
end

# Attach image to user message
function attach_images_to_user_message(prompt::AbstractString;
        image_url::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing,
        image_path::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing,
        kwargs...)
    UserMessageWithImages(prompt; image_url, image_path)
end
function attach_images_to_user_message(msg::UserMessageWithImages; kwargs...)
    throw(AssertionError("Cannot attach additional images to UserMessageWithImages."))
end
function attach_images_to_user_message(msg::UserMessage;
        image_url::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing,
        image_path::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing,
        kwargs...)
    UserMessageWithImages(msg.content; image_url, image_path)
end
# automatically attach images to the latest user message, if not allowed, throw an error if more than 2 user messages provided
function attach_images_to_user_message(msgs::Vector{T};
        image_url::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing,
        image_path::Union{Nothing, AbstractString, Vector{<:AbstractString}} = nothing,
        attach_to_latest::Bool = true) where {T <: AbstractChatMessage}
    # Check how to add images to UserMessage
    count_user_msgs = count(isusermessage, msgs)
    @assert attach_to_latest||(count_user_msgs <= 1) "At most one user message must be provided. Otherwise we would not know where to attach the images!"
    @assert count_user_msgs>0 "At least one user message must be provided."
    ##
    idx = findlast(isusermessage, msgs)
    # re-type to accept UserMessageWithImages type
    msgs = convert(Vector{typejoin(UserMessageWithImages, T)}, msgs)
    msgs[idx] = attach_images_to_user_message(msgs[idx]; image_url, image_path)
    return msgs
end

## Display methods
function Base.show(io::IO, ::MIME"text/plain", m::AbstractChatMessage)
    type_ = string(typeof(m)) |> x -> split(x, "{")[begin]
    if m isa AIMessage
        printstyled(io, type_; color = :magenta)
    elseif m isa SystemMessage
        printstyled(io, type_; color = :light_green)
    elseif m isa UserMessage || m isa UserMessageWithImages
        printstyled(io, type_; color = :light_red)
    elseif m isa MetadataMessage
        printstyled(io, type_; color = :light_blue)
    else
        print(io, type_)
    end
    print(io, "(\"", m.content, "\")")
end
function Base.show(io::IO, ::MIME"text/plain", m::AbstractDataMessage)
    type_ = string(typeof(m)) |> x -> split(x, "{")[begin]
    printstyled(io, type_; color = :light_yellow)
    # for Embedding messages
    if m.content isa AbstractArray
        print(io, "(", typeof(m.content), " of size ", size(m.content), ")")
        # for any non-types extraction messages
    elseif m.content isa Dict{Symbol, <:Any}
        print(io, "(Dict with keys: ", join(keys(m.content), ", "), ")")
    else
        print(io, "(", typeof(m.content), ")")
    end
end

## Dispatch for render
function render(schema::AbstractPromptSchema,
        messages::Vector{<:AbstractMessage};
        kwargs...)
    render(schema, messages; kwargs...)
end
function render(schema::AbstractPromptSchema, msg::AbstractMessage; kwargs...)
    render(schema, [msg]; kwargs...)
end
function render(schema::AbstractPromptSchema, msg::AbstractString; kwargs...)
    render(schema, [UserMessage(; content = msg)]; kwargs...)
end

## Serialization via JSON3
StructTypes.StructType(::Type{AbstractChatMessage}) = StructTypes.AbstractType()
StructTypes.StructType(::Type{MetadataMessage}) = StructTypes.Struct()
StructTypes.StructType(::Type{SystemMessage}) = StructTypes.Struct()
StructTypes.StructType(::Type{UserMessage}) = StructTypes.Struct()
StructTypes.StructType(::Type{AIMessage}) = StructTypes.Struct()
StructTypes.subtypekey(::Type{AbstractChatMessage}) = :_type
function StructTypes.subtypes(::Type{AbstractChatMessage})
    (usermessage = UserMessage,
        aimessage = AIMessage,
        systemmessage = SystemMessage,
        metadatamessage = MetadataMessage)
end