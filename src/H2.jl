module H2

include("Η2Errors.jl") 
include("Η2Exceptions.jl")
include("H2Settings.jl")
include("Config.jl")
include("Windows.jl")
include("Events.jl") 
include("Connection.jl")


using .H2Errors
using .H2Exceptions
using .Events
using .H2Settings
using .Config
using .H2Windows
using .Connection: H2Connection, send_headers, send_data,
 data_to_send, receive_data!, send_settings, acknowledge_received_data!, initiate_connection!, prioritize!


export Settings, ChangedSetting
export H2Config
export H2Connection, send_headers, send_data, data_to_send, receive_data!, send_settings,
       Event, RequestReceived, ResponseReceived, DataReceived, StreamEnded,
       SettingsChanged, WindowUpdated, StreamReset, ConnectionTerminated

export H2Error,
       ProtocolError,
       FrameTooLargeError,
       FrameDataMissingError,
       TooManyStreamsError,
       FlowControlError,
       StreamIDTooLowError,
       NoAvailableStreamIDError,
       NoSuchStreamError,
       StreamClosedError,
       InvalidSettingsValueError,
       InvalidBodyLengthError,
       UnsupportedFrameError,
       DenialOfServiceError,
       RFC1122Error

export ERROR_CODES, error_code_name,
       NO_ERROR, PROTOCOL_ERROR, INTERNAL_ERROR, FLOW_CONTROL_ERROR,
       SETTINGS_TIMEOUT, STREAM_CLOSED, FRAME_SIZE_ERROR, REFUSED_STREAM,
       CANCEL, COMPRESSION_ERROR, CONNECT_ERROR, ENHANCE_YOUR_CALM,
       INADEQUATE_SECURITY, HTTP_1_1_REQUIRED

export WindowManager, window_consumed!, window_opened!, process_bytes!

export Event, RequestReceived, ResponseReceived, DataReceived, StreamEnded,
       SettingsChanged, WindowUpdated, StreamReset, ConnectionTerminated,
       PriorityChanged, PingReceived, PingAck, InformationalResponseReceived, H2CUpgradeReceived

end 