module Routing

using HTTP
using JSON3
using Logging
using Sockets
using Http2Frames

using Http2Proto.Connection: H2Connection, send_headers, send_data, data_to_send
using Http2Proto.Events


export Router, route!, handle_request, start_router
export @get, @post, @put, @delete, @patch, @head, @options
export Request, Response, Context

"""
    Request

Represents an HTTP/2 request with all relevant information.
"""
struct Request
    method::String
    path::String
    headers::Vector{Pair{String, String}}
    body::Vector{UInt8}
    stream_id::Int
    query_params::Dict{String, String}
    path_params::Dict{String, String} 
end

"""
    Response

Represents an HTTP/2 response to be sent back to the client.
"""
mutable struct Response
    status::Int
    headers::Vector{Pair{String, String}}
    body::Vector{UInt8}
    
    Response(status::Int = 200) = new(status, Pair{String, String}[], UInt8[])
end

"""
    Context

Holds the request, response, and connection information for a handler.
"""
struct Context
    request::Request
    response::Response
    conn::H2Connection
    socket::IO
end

"""
    RouteHandler

Function signature for route handlers.
"""
const RouteHandler = Function

"""
    Route

Represents a single route with method, path pattern, and handler.
"""
struct Route
    method::String
    path_pattern::String
    handler::RouteHandler
    path_regex::Regex
    param_names::Vector{String}
end

"""
    Router

Main router class that manages all routes and middleware.
"""
mutable struct Router
    routes::Vector{Route}
    middleware::Vector{Function}
    not_found_handler::Union{RouteHandler, Nothing}
    error_handler::Union{Function, Nothing}
    
    Router() = new(Route[], Function[], nothing, nothing)
end

"""
    route!(router::Router, method::String, path::String, handler::RouteHandler)

Add a route to the router.
"""
function route!(router::Router, method::String, path::String, handler::RouteHandler)
    path_regex, param_names = compile_path_pattern(path)
    route = Route(uppercase(method), path, handler, path_regex, param_names)
    push!(router.routes, route)
    return router
end

"""
    compile_path_pattern(path::String) -> (Regex, Vector{String})

Compile a path pattern like "/users/:id/posts/:post_id" into a regex and parameter names.
"""
function compile_path_pattern(path::String)
    param_names = String[]
    regex_pattern = path
    
    for match in eachmatch(r":([a-zA-Z_][a-zA-Z0-9_]*)", path)
        param_name = match.captures[1]
        push!(param_names, param_name)
        regex_pattern = replace(regex_pattern, ":$param_name" => "(?<$param_name>[^/]+)")
    end
    
    regex_pattern = "^" * regex_pattern * "\$"
    
    return Regex(regex_pattern), param_names
end

"""
    parse_query_string(query::String) -> Dict{String, String}

Parse URL query string into a dictionary.
"""
function parse_query_string(query::String)
    params = Dict{String, String}()
    if isempty(query)
        return params
    end
    
    for pair in split(query, '&')
        if '=' in pair
            key, value = split(pair, '=', limit=2)
            params[HTTP.URIs.unescapeuri(key)] = HTTP.URIs.unescapeuri(value)
        else
            params[HTTP.URIs.unescapeuri(pair)] = ""
        end
    end
    
    return params
end

"""
    create_request(event::Events.RequestReceived, body::Vector{UInt8} = UInt8[]) -> Request

Create a Request object from an HTTP/2 RequestReceived event.
"""
function create_request(event::Events.RequestReceived, body::Vector{UInt8} = UInt8[])
    method = ""
    path = ""
    
    for (name, value) in event.headers
        if name == ":method"
            method = value
        elseif name == ":path"
            path = value
        end
    end
    
    uri = HTTP.URIs.URI(path)
    query_params = parse_query_string(String(uri.query))
    
    return Request(
        method,
        uri.path,
        event.headers,
        body,
        event.stream_id,
        query_params,
        Dict{String, String}()
    )
end

"""
    match_route(router::Router, request::Request) -> Union{Route, Nothing}

Find a matching route for the given request.
"""
function match_route(router::Router, request::Request)
    for route in router.routes
        if route.method == request.method || route.method == "ANY"
            match_result = match(route.path_regex, request.path)
            if match_result !== nothing
                for param_name in route.param_names
                    if haskey(match_result, param_name)
                        request.path_params[param_name] = match_result[param_name]
                    end
                end
                return route
            end
        end
    end
    return nothing
end

"""
    handle_request(router::Router, conn::H2Connection, event::Events.RequestReceived, socket::IO, body::Vector{UInt8} = UInt8[])

Main request handling function that processes incoming HTTP/2 requests.
"""
function handle_request(router::Router, conn::H2Connection, event::Events.RequestReceived, socket::IO, body::Vector{UInt8} = UInt8[])
    request = create_request(event, body)
    response = Response()
    context = Context(request, response, conn, socket)
    
    try
        for middleware in router.middleware
            middleware(context)
        end
        
        route = match_route(router, request)
        
        if route !== nothing
            route.handler(context)
        else
            # Handle 404
            if router.not_found_handler !== nothing
                router.not_found_handler(context)
            else
                default_404_handler(context)
            end
        end
        
    catch e
        @error "Error handling request: $e" _exception=(e, catch_backtrace())
        if router.error_handler !== nothing
            router.error_handler(context, e)
        else
            default_error_handler(context, e)
        end
    end
    
    send_response(context)
end

"""
    send_response(context::Context)

Send the HTTP/2 response back to the client.
"""
function send_response(context::Context)
    response = context.response
    
    status_header_found = false
    for (i, header) in enumerate(response.headers)
        if header.first == ":status"
            if i != 1
                deleteat!(response.headers, i)
                pushfirst!(response.headers, ":status" => string(response.status))
            end
            status_header_found = true
            break
        end
    end
    if !status_header_found
        pushfirst!(response.headers, ":status" => string(response.status))
    end
    
    final_headers = filter(p -> !isempty(p.first) && !isempty(p.second), response.headers)
    
    send_headers(context.conn, UInt32(context.request.stream_id), final_headers)
    
    if !isempty(response.body)
        send_data(context.conn, UInt32(context.request.stream_id), response.body, end_stream=true)
    else
        send_data(context.conn, UInt32(context.request.stream_id), UInt8[], end_stream=true)
    end
    
    bytes_to_send = data_to_send(context.conn)
    if !isempty(bytes_to_send)
        write(context.socket, bytes_to_send)
        flush(context.socket)
    end
end

"""
    default_404_handler(context::Context)

Default handler for 404 Not Found responses.
"""
function default_404_handler(context::Context)
    context.response.status = 404
    set_header!(context.response, "content-type", "text/plain; charset=utf-8")
    set_body!(context.response, "Not Found: $(context.request.path)")
end

"""
    default_error_handler(context::Context, error::Exception)

Default error handler for unhandled exceptions.
"""
function default_error_handler(context::Context, error::Exception)
    context.response.status = 500
    set_header!(context.response, "content-type", "text/plain; charset=utf-8")
    set_body!(context.response, "Internal Server Error")
end

"""
    set_header!(response::Response, name::String, value::String)

Set a header in the response. Ensures header names are lowercase for HTTP/2.
"""
function set_header!(response::Response, name::String, value::String)
    lower_name = lowercase(name)
    filter!(header -> lowercase(header.first) != lower_name, response.headers)
    push!(response.headers, lower_name => value)
end

"""
    set_body!(response::Response, body::Union{String, Vector{UInt8}})

Set the response body.
"""
function set_body!(response::Response, body::Union{String, Vector{UInt8}})
    if body isa String
        response.body = Vector{UInt8}(body)
    else
        response.body = body
    end
end

"""
    json_response!(context::Context, data, status::Int = 200)

Send a JSON response.
"""
function json_response!(context::Context, data, status::Int = 200)
    context.response.status = status
    set_header!(context.response, "content-type", "application/json; charset=utf-8")
    json_string = JSON3.write(data)
    set_body!(context.response, json_string)
end

"""
    text_response!(context::Context, text::String, status::Int = 200)

Send a plain text response.
"""
function text_response!(context::Context, text::String, status::Int = 200)
    context.response.status = status
    set_header!(context.response, "content-type", "text/plain; charset=utf-8")
    set_body!(context.response, text)
end

"""
    html_response!(context::Context, html::String, status::Int = 200)

Send an HTML response.
"""
function html_response!(context::Context, html::String, status::Int = 200)
    context.response.status = status
    set_header!(context.response, "content-type", "text/html; charset=utf-8")
    set_body!(context.response, html)
end

"""
    redirect!(context::Context, url::String, status::Int = 302)

Send a redirect response.
"""
function redirect!(context::Context, url::String, status::Int = 302)
    context.response.status = status
    set_header!(context.response, "location", url)
    set_body!(context.response, "")
end

"""
    get_header(request::Request, name::String) -> Union{String, Nothing}

Get a header value from the request (case-insensitive).
"""
function get_header(request::Request, name::String)
    lower_name = lowercase(name)
    for (header_name, header_value) in request.headers
        if lowercase(header_name) == lower_name 
            return header_value
        end
    end
    return nothing
end

"""
    get_json_body(request::Request) -> Any

Parse the request body as JSON.
"""
function get_json_body(request::Request)
    if isempty(request.body)
        return nothing
    end
    try
        return JSON3.read(request.body)
    catch e
        @error "Failed to parse JSON body: $e" _exception=(e, catch_backtrace())
        rethrow(e) # Re-throw if needed to be caught by the main handler's try-catch block
    end
end

"""
    get_form_data(request::Request) -> Dict{String, String}

Parse form-encoded request body.
"""
function get_form_data(request::Request)
    if isempty(request.body)
        return Dict{String, String}()
    end
    
    body_string = String(request.body)
    return parse_query_string(body_string)
end

"""
    use_middleware!(router::Router, middleware::Function)

Add middleware to the router.
"""
function use_middleware!(router::Router, middleware::Function)
    push!(router.middleware, middleware)
    return router
end

"""
    cors_middleware(context::Context)

CORS middleware that adds appropriate headers (lowercase for HTTP/2 compliance).
"""
function cors_middleware(context::Context)
    set_header!(context.response, "access-control-allow-origin", "*")
    set_header!(context.response, "access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS, HEAD, PATCH")
    set_header!(context.response, "access-control-allow-headers", "content-type, authorization, x-requested-with")
    set_header!(context.response, "access-control-allow-credentials", "true") 
    
    if context.request.method == "OPTIONS"
        context.response.status = 200
        set_body!(context.response, "")
        return 
    end
    # For other methods, the request will continue to the next middleware/handler
end


"""
    logging_middleware(context::Context)

Logging middleware that logs requests.
"""
function logging_middleware(context::Context)
    @info "$(context.request.method) $(context.request.path) - Stream $(context.request.stream_id)"
    # Middleware must explicitly call the next handler if it's not the last one in the chain.
    # Current middleware design is sequential, so `handle_request` directly calls `middleware(context)`.
    # A common pattern for middleware is: `function my_middleware(handler_chain)` and it returns `function(ctx) handler_chain(ctx) ... end`
    # However, your `handle_request` iterates and calls each middleware, which is simpler but means
    # middleware needs to affect `context.response` and rely on `send_response` at the end.
end

"""
    handle_ping(conn::H2Connection, event::Events.PingReceived, socket::IO)

Handle HTTP/2 PING frames.
"""
function handle_ping(conn::H2Connection, event::Events.PingReceived, socket::IO)
    @info "Received PING with data: $(event.data)"
    # PING responses are automatically handled by the H2Connection to send a PING_ACK.
    # This function is primarily for logging or custom side-effects if needed.
end

"""
    handle_push_promise(context::Context, path::String, headers::Vector{Pair{String, String}})

[Inference] Handle HTTP/2 Server Push (if supported by your H2 implementation).
Note: This is expected behavior based on HTTP/2 specification, not guaranteed to work with your specific H2 implementation.
"""
function handle_push_promise(context::Context, path::String, headers::Vector{Pair{String, String}})
    @info "Server push requested for path: $path"
end

"""
    handle_upgrade(conn::H2Connection, event::Events.H2CUpgradeReceived, socket::IO)

Handle HTTP/1.1 to HTTP/2 upgrade requests.
"""
function handle_upgrade(conn::H2Connection, event::Events.H2CUpgradeReceived, socket::IO)
    @info "HTTP/1.1 to HTTP/2 upgrade received"
end

"""
    @get(router, path, handler)

Macro for defining GET routes.
"""
macro get(router, path, handler)
    quote
        route!($(esc(router)), "GET", $(esc(path)), $(esc(handler)))
    end
end

"""
    @post(router, path, handler)

Macro for defining POST routes.
"""
macro post(router, path, handler)
    quote
        route!($(esc(router)), "POST", $(esc(path)), $(esc(handler)))
    end
end

"""
    @put(router, path, handler)

Macro for defining PUT routes.
"""
macro put(router, path, handler)
    quote
        route!($(esc(router)), "PUT", $(esc(path)), $(esc(handler)))
    end
end

"""
    @delete(router, path, handler)

Macro for defining DELETE routes.
"""
macro delete(router, path, handler)
    quote
        route!($(esc(router)), "DELETE", $(esc(path)), $(esc(handler)))
    end
end

"""
    @patch(router, path, handler)

Macro for defining PATCH routes.
"""
macro patch(router, path, handler)
    quote
        route!($(esc(router)), "PATCH", $(esc(path)), $(esc(handler)))
    end
end

"""
    @head(router, path, handler)

Macro for defining HEAD routes.
"""
macro head(router, path, handler)
    quote
        route!($(esc(router)), "HEAD", $(esc(path)), $(esc(handler)))
    end
end

"""
    @options(router, path, handler)

Macro for defining OPTIONS routes.
"""
macro options(router, path, handler)
    quote
        route!($(esc(router)), "OPTIONS", $(esc(path)), $(esc(handler)))
    end
end

"""
    start_router() -> Router

Create and return a new router instance with basic middleware.
"""
function start_router()
    router = Router()
    use_middleware!(router, logging_middleware)
    return router
end

end