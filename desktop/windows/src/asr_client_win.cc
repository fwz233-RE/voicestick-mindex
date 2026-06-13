#include "asr_client_win.h"

#include "asr_protocol.h"
#include "byte_utils.h"

#include <bcrypt.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace voicestick {

namespace {

std::wstring Utf16FromUtf8(std::string_view text) {
    if (text.empty()) return {};
    const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                           static_cast<int>(text.size()), nullptr, 0);
    if (length <= 0) return {};
    std::wstring wide(static_cast<std::size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        wide.data(), length);
    return wide;
}

bool StartsWithScheme(std::string_view text, std::string_view scheme) {
    return text.size() >= scheme.size() &&
           std::equal(scheme.begin(), scheme.end(), text.begin(), [](char lhs, char rhs) {
               return std::tolower(static_cast<unsigned char>(lhs)) ==
                      std::tolower(static_cast<unsigned char>(rhs));
           });
}

constexpr int kAsrResolveTimeoutMs = 5000;
constexpr int kAsrConnectTimeoutMs = 5000;
constexpr int kAsrSendTimeoutMs = 5000;
constexpr int kAsrReceiveTimeoutMs = 15000;
constexpr int kAliyunSampleRate = 16000;

std::string JsonEscape(std::string_view text) {
    std::string out;
    out.reserve(text.size() + 8);
    for (char ch : text) {
        switch (ch) {
        case '\\': out += "\\\\"; break;
        case '"': out += "\\\""; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default: out.push_back(ch); break;
        }
    }
    return out;
}

std::string JsonStringValue(std::string_view json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    const auto key_pos = json.find(needle);
    if (key_pos == std::string_view::npos) return {};
    const auto colon = json.find(':', key_pos + needle.size());
    if (colon == std::string_view::npos) return {};
    const auto first_quote = json.find('"', colon + 1);
    if (first_quote == std::string_view::npos) return {};
    std::string out;
    bool escaped = false;
    for (auto i = first_quote + 1; i < json.size(); ++i) {
        char ch = json[i];
        if (escaped) {
            out.push_back(ch);
            escaped = false;
        } else if (ch == '\\') {
            escaped = true;
        } else if (ch == '"') {
            return out;
        } else {
            out.push_back(ch);
        }
    }
    return {};
}

std::string AliyunTaskId(std::string_view session_id) {
    std::string out;
    out.reserve(32);
    for (char ch : session_id) {
        if (std::isxdigit(static_cast<unsigned char>(ch))) {
            out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(ch))));
            if (out.size() == 32) break;
        }
    }
    return out;
}

std::string AliyunRunTaskJson(const AppConfig& config, std::string_view task_id) {
    const auto model = config.aliyun_asr_model.empty() ? std::string("fun-asr-realtime") : config.aliyun_asr_model;
    const auto normalized_task_id = AliyunTaskId(task_id);
    return "{\"header\":{\"action\":\"run-task\",\"task_id\":\"" + JsonEscape(normalized_task_id) +
           "\",\"streaming\":\"duplex\"},\"payload\":{\"task_group\":\"audio\",\"task\":\"asr\","
           "\"function\":\"recognition\",\"model\":\"" + JsonEscape(model) +
           "\",\"parameters\":{\"sample_rate\":" + std::to_string(kAliyunSampleRate) +
           ",\"format\":\"opus\"},\"input\":{}}}";
}

std::string AliyunFinishTaskJson(std::string_view task_id) {
    const auto normalized_task_id = AliyunTaskId(task_id);
    return "{\"header\":{\"action\":\"finish-task\",\"task_id\":\"" + JsonEscape(normalized_task_id) +
           "\",\"streaming\":\"duplex\"},\"payload\":{\"input\":{}}}";
}

std::string AliyunSentenceText(std::string_view json) {
    auto text = JsonStringValue(json, "text");
    return text;
}

bool AliyunSentenceEnd(std::string_view json) {
    const std::string needle = "\"sentence_end\"";
    const auto key_pos = json.find(needle);
    if (key_pos == std::string_view::npos) return false;
    const auto colon = json.find(':', key_pos + needle.size());
    if (colon == std::string_view::npos) return false;
    auto value_pos = json.find_first_not_of(" \t\r\n", colon + 1);
    if (value_pos == std::string_view::npos) return false;
    return json.substr(value_pos, 4) == "true" || json.substr(value_pos, 1) == "1";
}

std::string AliyunErrorMessage(std::string_view json) {
    auto message = JsonStringValue(json, "error_message");
    if (!message.empty()) return message;
    message = JsonStringValue(json, "message");
    return message.empty() ? std::string(json) : message;
}

void SetAsrWinHttpTimeouts(HINTERNET handle) {
    if (!handle) return;
    WinHttpSetTimeouts(handle,
                       kAsrResolveTimeoutMs,
                       kAsrConnectTimeoutMs,
                       kAsrSendTimeoutMs,
                       kAsrReceiveTimeoutMs);
}

std::optional<std::wstring> WinHttpUrlFromWebSocketUrl(std::string_view websocket_url) {
    std::string http_url;
    if (StartsWithScheme(websocket_url, "wss://")) {
        http_url = "https://";
        http_url.append(websocket_url.substr(6));
    } else if (StartsWithScheme(websocket_url, "ws://")) {
        http_url = "http://";
        http_url.append(websocket_url.substr(5));
    } else {
        http_url = std::string(websocket_url);
    }

    auto wide = Utf16FromUtf8(http_url);
    if (wide.empty()) return std::nullopt;
    return wide;
}

} // namespace

AsrClientWin::AsrClientWin(AppConfig config) : config_(std::move(config)) {}

AsrClientWin::~AsrClientWin() {
    ShutdownReusableConnection();
}

bool AsrClientWin::Start(AsrSessionOptions options) {
    SetLastStartError({});
    if (config_.ActiveApiKey().empty()) {
        SetLastStartError("Missing ASR API key");
        return false;
    }
    session_options_ = std::move(options);
    if (session_options_.hotwords.empty()) {
        session_options_.hotwords = config_.asr_hotwords;
    }
    emitted_definite_segment_keys_.clear();
    aliyun_transcript_accumulator_.Reset();
    return StartReusableSession();
}

bool AsrClientWin::StartReusableSession() {
    std::string ready_session_id;
    bool has_ready_websocket = false;
    {
        std::lock_guard lock(mutex_);
        if (session_state_ != SessionState::kIdle) {
            last_start_error_ = "ASR session already active";
            return false;
        }
        current_session_id_ = GenerateSessionId();
        latest_session_transcript_.clear();
        aliyun_transcript_accumulator_.Reset();
        queued_audio_chunks_.clear();
        session_state_ = SessionState::kStarting;
        if (connection_state_ == ConnectionState::kReady && websocket_) {
            has_ready_websocket = true;
            ready_session_id = current_session_id_;
        }
        if (connection_state_ == ConnectionState::kConnecting && worker_.joinable()) {
            return true;
        }
    }
    if (has_ready_websocket) {
        if (config_.asr_provider == AsrProvider::kAliyun) {
            return SendAliyunRunTaskFrame(ready_session_id);
        }
        return SendReusableFrameOrFail(
            AsrProtocol::MakeStartSessionFrame(config_, ready_session_id, session_options_),
            "start ASR session");
    }

    ShutdownReusableConnection();
    {
        std::lock_guard lock(mutex_);
        if (session_state_ == SessionState::kIdle) {
            current_session_id_ = GenerateSessionId();
            session_state_ = SessionState::kStarting;
        }
        connection_state_ = ConnectionState::kConnecting;
    }
    cancelled_ = false;
    worker_ = std::thread([this] { RunReusableWebSocket(); });
    return true;
}

void AsrClientWin::SendOggOpusChunk(std::span<const std::uint8_t> data, bool is_last) {
    SendReusableAudio(data, is_last);
}

void AsrClientWin::Cancel() {
    CancelReusableSession();
}

std::string AsrClientWin::LastStartError() const {
    std::lock_guard lock(mutex_);
    return last_start_error_;
}

void AsrClientWin::CancelReusableSession() {
    HINTERNET websocket = nullptr;
    std::string session_id;
    bool should_send_cancel = false;
    {
        std::lock_guard lock(mutex_);
        queued_audio_chunks_.clear();
        latest_session_transcript_.clear();
        aliyun_transcript_accumulator_.Reset();
        emitted_definite_segment_keys_.clear();
        should_send_cancel = session_state_ == SessionState::kStarting ||
                             session_state_ == SessionState::kStreaming ||
                             session_state_ == SessionState::kFinishing;
        websocket = websocket_;
        session_id = current_session_id_;
        current_session_id_.clear();
        session_state_ = SessionState::kIdle;
    }
    if (should_send_cancel && websocket && !session_id.empty()) {
        if (config_.asr_provider == AsrProvider::kAliyun) {
            const auto frame = AliyunFinishTaskJson(session_id);
            WinHttpWebSocketSend(websocket,
                                 WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                                 reinterpret_cast<void*>(const_cast<char*>(frame.data())),
                                 static_cast<DWORD>(frame.size()));
        } else {
            SendFrame(websocket, AsrProtocol::MakeCancelSessionFrame(
                config_, session_id, session_options_));
        }
    }
}

void AsrClientWin::ShutdownReusableConnection() {
    cancelled_ = true;
    const bool has_worker = worker_.joinable();
    {
        std::lock_guard lock(mutex_);
        if (websocket_) {
            if (connection_state_ == ConnectionState::kReady &&
                config_.asr_provider != AsrProvider::kAliyun) {
                SendFrame(websocket_,
                          AsrProtocol::MakeFinishConnectionFrame(config_, session_options_));
            }
            WinHttpWebSocketClose(websocket_,
                                  WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS,
                                  nullptr,
                                  0);
            if (!has_worker) {
                WinHttpCloseHandle(websocket_);
                websocket_ = nullptr;
            }
        }
        queued_audio_chunks_.clear();
        current_session_id_.clear();
        latest_session_transcript_.clear();
        aliyun_transcript_accumulator_.Reset();
        emitted_definite_segment_keys_.clear();
        session_state_ = SessionState::kIdle;
        connection_state_ = ConnectionState::kDisconnected;
    }
    if (worker_.joinable()) {
        if (worker_.get_id() == std::this_thread::get_id()) {
            worker_.detach();
        } else {
            worker_.join();
        }
    }
}

void AsrClientWin::RunReusableWebSocket() {
    URL_COMPONENTSW components{};
    components.dwStructSize = sizeof(components);
    components.dwSchemeLength = static_cast<DWORD>(-1);
    components.dwHostNameLength = static_cast<DWORD>(-1);
    components.dwUrlPathLength = static_cast<DWORD>(-1);
    components.dwExtraInfoLength = static_cast<DWORD>(-1);
    const auto url = WinHttpUrlFromWebSocketUrl(config_.ActiveWebsocketUrl());
    if (!url.has_value() || !WinHttpCrackUrl(url->c_str(), 0, 0, &components)) {
        FailReusableSession("Invalid ASR URL");
        return;
    }

    HINTERNET session = WinHttpOpen(L"VoiceStick/Windows", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                   WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        FailReusableSession("Failed to start ASR network session: " + LastErrorText());
        return;
    }
    SetAsrWinHttpTimeouts(session);
    std::wstring host(components.lpszHostName, components.dwHostNameLength);
    HINTERNET connect = WinHttpConnect(session, host.c_str(), components.nPort, 0);
    if (!connect) {
        CloseHandles(session, nullptr, nullptr, nullptr);
        FailReusableSession("Failed to connect ASR host: " + LastErrorText());
        return;
    }
    const DWORD flags = components.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
    std::wstring path_and_query;
    if (components.lpszUrlPath && components.dwUrlPathLength > 0) {
        path_and_query.assign(components.lpszUrlPath, components.dwUrlPathLength);
    }
    if (components.lpszExtraInfo && components.dwExtraInfoLength > 0) {
        path_and_query.append(components.lpszExtraInfo, components.dwExtraInfoLength);
    }
    if (path_and_query.empty()) path_and_query = L"/";
    HINTERNET request = WinHttpOpenRequest(connect, L"GET", path_and_query.c_str(), nullptr,
                                           WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        CloseHandles(session, connect, request, nullptr);
        FailReusableSession("Failed to create ASR request: " + LastErrorText());
        return;
    }
    SetAsrWinHttpTimeouts(request);

    if (config_.asr_provider == AsrProvider::kAliyun) {
        AddHeader(request, "Authorization", "bearer " + config_.ActiveApiKey());
    } else {
        AddHeader(request, "X-Api-Key", config_.ActiveApiKey());
        AddHeader(request, "X-Api-Request-Id", GenerateSessionId());
        AddHeader(request, "X-Api-Sequence", "-1");
        if (config_.asr_provider == AsrProvider::kVoiceStickCloud) {
            if (!config_.paired_device_ids.empty()) {
                AddHeader(request, "X-Device-Id", config_.paired_device_ids.front());
            }
        } else {
            AddHeader(request, "X-Api-Resource-Id", config_.resource_id);
        }
    }

    if (!WinHttpSetOption(request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) {
        CloseHandles(session, connect, request, nullptr);
        FailReusableSession("Failed to prepare ASR WebSocket upgrade");
        return;
    }
    if (!WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request, nullptr)) {
        CloseHandles(session, connect, request, nullptr);
        FailReusableSession("ASR WebSocket handshake failed");
        return;
    }

    HINTERNET websocket = WinHttpWebSocketCompleteUpgrade(request, 0);
    if (!websocket) {
        const auto status_code = QueryStatusCode(request);
        CloseHandles(session, connect, request, nullptr);
        FailReusableSession(status_code.empty()
                            ? "ASR WebSocket upgrade failed"
                            : "ASR WebSocket upgrade failed: HTTP " + status_code);
        return;
    }
    SetAsrWinHttpTimeouts(websocket);
    WinHttpCloseHandle(request);
    request = nullptr;

    {
        std::lock_guard lock(mutex_);
        websocket_ = websocket;
        connection_state_ = ConnectionState::kConnecting;
    }
    if (config_.asr_provider == AsrProvider::kAliyun) {
        std::string task_id;
        {
            std::lock_guard lock(mutex_);
            connection_state_ = ConnectionState::kReady;
            task_id = current_session_id_;
        }
        if (!SendAliyunRunTaskFrame(task_id)) {
            CloseHandles(session, connect, request, websocket);
            return;
        }
    } else if (!SendReusableFrameOrFail(AsrProtocol::MakeStartConnectionFrame(config_, session_options_),
                                        "start ASR connection")) {
        CloseHandles(session, connect, request, websocket);
        return;
    }
    while (!cancelled_) {
        ReceiveOneReusable(websocket);
    }
    {
        std::lock_guard lock(mutex_);
        if (websocket_ == websocket) websocket_ = nullptr;
        connection_state_ = ConnectionState::kDisconnected;
    }
    CloseHandles(session, connect, request, websocket);
}

void AsrClientWin::FlushQueuedAudioChunks() {
    std::vector<QueuedAudioChunk> chunks;
    std::string session_id;
    {
        std::lock_guard lock(mutex_);
        chunks.swap(queued_audio_chunks_);
        session_id = current_session_id_;
    }
    for (const auto& chunk : chunks) {
        if (config_.asr_provider == AsrProvider::kAliyun) {
            if (!SendReusableFrameOrFail(chunk.data, "send ASR audio")) {
                return;
            }
        } else if (!SendReusableFrameOrFail(AsrProtocol::MakeTaskRequestFrame(chunk.data, session_id),
                                            "send ASR audio")) {
            return;
        }
        if (chunk.is_last) {
            FinishReusableSessionIfNeeded();
        }
    }
}

bool AsrClientWin::SendFrame(HINTERNET websocket, const ByteVector& frame) {
    return WinHttpWebSocketSend(websocket,
                                WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
                                const_cast<std::uint8_t*>(frame.data()),
                                static_cast<DWORD>(frame.size())) == ERROR_SUCCESS;
}

void AsrClientWin::ReceiveOneReusable(HINTERNET websocket) {
    std::array<std::uint8_t, 64 * 1024> buffer{};
    DWORD bytes_read = 0;
    WINHTTP_WEB_SOCKET_BUFFER_TYPE type{};
    const DWORD result = WinHttpWebSocketReceive(websocket, buffer.data(),
                                                 static_cast<DWORD>(buffer.size()),
                                                 &bytes_read, &type);
    if (result == ERROR_WINHTTP_TIMEOUT) return;
    if (result != ERROR_SUCCESS) {
        if (cancelled_.load()) return;
        FailReusableSession("ASR WebSocket receive failed: " + std::to_string(result));
        return;
    }
    if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
        if (cancelled_.load()) return;
        FailReusableSession("ASR WebSocket disconnected");
        return;
    }
    if (bytes_read == 0) return;
    if (type != WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE &&
        type != WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE &&
        type != WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE &&
        type != WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE) {
        return;
    }
    if (config_.asr_provider == AsrProvider::kAliyun) {
        HandleAliyunResponse(std::span(buffer.data(), bytes_read));
        return;
    }
    HandleReusableResponse(std::span(buffer.data(), bytes_read), websocket);
}

void AsrClientWin::HandleReusableResponse(std::span<const std::uint8_t> data, HINTERNET websocket) {
    if (data.size() < 4) {
        FailReusableSession("Short ASR response");
        return;
    }
    const std::uint8_t message_type = data[1] >> 4;
    if (message_type == 0x0f) {
        auto response = AsrProtocol::ParseResponse(data);
        if (response && response->is_error) {
            FailReusableSession(response->text);
            if (response->upgrade_url && on_upgrade_url) {
                on_upgrade_url(*response->upgrade_url, response->text);
            }
        }
        return;
    }

    auto event_response = AsrProtocol::ParseEventResponse(data);
    if (!event_response.has_value()) {
        return;
    }

    const auto& response = *event_response;
    switch (response.event.value_or(static_cast<AsrEvent>(0))) {
    case AsrEvent::kConnectionStarted: {
        std::string session_id;
        bool should_start_session = false;
        {
            std::lock_guard lock(mutex_);
            connection_state_ = ConnectionState::kReady;
            should_start_session = session_state_ == SessionState::kStarting;
            session_id = current_session_id_;
        }
        if (should_start_session && !session_id.empty()) {
            SendReusableFrameOrFail(AsrProtocol::MakeStartSessionFrame(config_, session_id, session_options_),
                                    "start ASR session");
        }
        break;
    }

    case AsrEvent::kConnectionFailed:
        FailReusableSession(response.payload_text.empty() ? "ASR connection failed" : response.payload_text);
        break;

    case AsrEvent::kConnectionFinished:
        {
            std::lock_guard lock(mutex_);
            connection_state_ = ConnectionState::kDisconnected;
            if (websocket_ == websocket) websocket_ = nullptr;
        }
        cancelled_ = true;
        break;

    case AsrEvent::kSessionStarted: {
        bool should_flush = false;
        {
            std::lock_guard lock(mutex_);
            if (response.session_id == current_session_id_) {
                session_state_ = SessionState::kStreaming;
                should_flush = true;
            }
        }
        if (should_flush) FlushQueuedAudioChunks();
        break;
    }

    case AsrEvent::kAsrResponse:
    case AsrEvent::kAsrInfo: {
        std::string transcript;
        std::vector<AsrSegment> segments;
        {
            std::lock_guard lock(mutex_);
            if (response.session_id != current_session_id_) return;
            transcript = AsrProtocol::ExtractTranscript(response.payload_text);
            if (!transcript.empty()) latest_session_transcript_ = transcript;
            segments = AsrProtocol::ExtractNewDefiniteSegments(
                response.payload_text, &emitted_definite_segment_keys_);
        }
        if (!transcript.empty() && on_partial) on_partial(transcript);
        for (const auto& segment : segments) {
            if (on_segment) on_segment(segment);
        }
        break;
    }

    case AsrEvent::kSessionFinished: {
        std::string final_text;
        std::vector<AsrSegment> segments;
        {
            std::lock_guard lock(mutex_);
            if (response.session_id != current_session_id_) return;
            final_text = AsrProtocol::ExtractTranscript(response.payload_text);
            if (final_text.empty()) final_text = latest_session_transcript_;
            segments = AsrProtocol::ExtractNewDefiniteSegments(
                response.payload_text, &emitted_definite_segment_keys_);
            current_session_id_.clear();
            latest_session_transcript_.clear();
            aliyun_transcript_accumulator_.Reset();
            emitted_definite_segment_keys_.clear();
            queued_audio_chunks_.clear();
            session_state_ = SessionState::kIdle;
        }
        for (const auto& segment : segments) {
            if (on_segment) on_segment(segment);
        }
        if (on_final) on_final(final_text);
        break;
    }

    case AsrEvent::kSessionCanceled:
        {
            std::lock_guard lock(mutex_);
            if (response.session_id == current_session_id_) {
                current_session_id_.clear();
                latest_session_transcript_.clear();
                emitted_definite_segment_keys_.clear();
                queued_audio_chunks_.clear();
                session_state_ = SessionState::kIdle;
            }
        }
        break;

    case AsrEvent::kAsrEnd:
    case AsrEvent::kUsageResponse:
        break;

    default:
        break;
    }
}

void AsrClientWin::SendReusableAudio(std::span<const std::uint8_t> data, bool is_last) {
    std::string session_id;
    SessionState state = SessionState::kIdle;
    {
        std::lock_guard lock(mutex_);
        state = session_state_;
        if (state == SessionState::kStarting || state == SessionState::kIdle) {
            queued_audio_chunks_.push_back(QueuedAudioChunk{ByteVector(data.begin(), data.end()), is_last});
            return;
        }
        if (state == SessionState::kFinishing) return;
        session_id = current_session_id_;
    }
    if (session_id.empty()) {
        FailReusableSession("ASR WebSocket is not connected");
        return;
    }
    if (config_.asr_provider == AsrProvider::kAliyun) {
        if (!SendReusableFrameOrFail(ByteVector(data.begin(), data.end()), "send ASR audio")) {
            return;
        }
    } else if (!SendReusableFrameOrFail(AsrProtocol::MakeTaskRequestFrame(data, session_id),
                                        "send ASR audio")) {
        return;
    }
    if (is_last) {
        FinishReusableSessionIfNeeded();
    }
}

void AsrClientWin::FinishReusableSessionIfNeeded() {
    std::string session_id;
    {
        std::lock_guard lock(mutex_);
        if (session_state_ == SessionState::kStarting) {
            const auto has_last = std::any_of(
                queued_audio_chunks_.begin(), queued_audio_chunks_.end(),
                [](const QueuedAudioChunk& chunk) { return chunk.is_last; });
            if (!has_last) queued_audio_chunks_.push_back(QueuedAudioChunk{{}, true});
            return;
        }
        if (session_state_ != SessionState::kStreaming || current_session_id_.empty()) return;
        session_state_ = SessionState::kFinishing;
        session_id = current_session_id_;
    }
    if (config_.asr_provider == AsrProvider::kAliyun) {
        SendAliyunFinishTaskFrame(session_id);
    } else {
        SendReusableFrameOrFail(AsrProtocol::MakeFinishSessionFrame(config_, session_id, session_options_),
                                "finish ASR session");
    }
}

void AsrClientWin::FailReusableSession(const std::string& message) {
    const bool was_cancelled = cancelled_.load();
    bool had_active_session = false;
    cancelled_ = true;
    {
        std::lock_guard lock(mutex_);
        had_active_session = session_state_ != SessionState::kIdle;
        queued_audio_chunks_.clear();
        current_session_id_.clear();
        latest_session_transcript_.clear();
        aliyun_transcript_accumulator_.Reset();
        session_state_ = SessionState::kIdle;
        connection_state_ = ConnectionState::kDisconnected;
        websocket_ = nullptr;
    }
    if (!was_cancelled && had_active_session && on_error) on_error(message);
}

bool AsrClientWin::SendReusableFrameOrFail(const ByteVector& frame, const std::string& context) {
    const auto message = "Failed to " + context;
    bool should_notify = false;
    {
        std::lock_guard lock(mutex_);
        if (websocket_ && WinHttpWebSocketSend(websocket_,
                                               WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
                                               const_cast<std::uint8_t*>(frame.data()),
                                               static_cast<DWORD>(frame.size())) == ERROR_SUCCESS) {
            return true;
        }

        const bool was_cancelled = cancelled_.load();
        const bool had_active_session = session_state_ != SessionState::kIdle;
        last_start_error_ = message;
        cancelled_ = true;
        queued_audio_chunks_.clear();
        current_session_id_.clear();
        latest_session_transcript_.clear();
        aliyun_transcript_accumulator_.Reset();
        session_state_ = SessionState::kIdle;
        connection_state_ = ConnectionState::kDisconnected;
        websocket_ = nullptr;
        should_notify = !was_cancelled && had_active_session;
    }
    if (should_notify && on_error) on_error(message);
    return false;
}

bool AsrClientWin::SendAliyunTextFrameOrFail(const std::string& text, const std::string& context) {
    const auto message = "Failed to " + context;
    bool should_notify = false;
    {
        std::lock_guard lock(mutex_);
        if (websocket_ && WinHttpWebSocketSend(websocket_,
                                               WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                                               reinterpret_cast<void*>(const_cast<char*>(text.data())),
                                               static_cast<DWORD>(text.size())) == ERROR_SUCCESS) {
            return true;
        }

        const bool was_cancelled = cancelled_.load();
        const bool had_active_session = session_state_ != SessionState::kIdle;
        last_start_error_ = message;
        cancelled_ = true;
        queued_audio_chunks_.clear();
        current_session_id_.clear();
        latest_session_transcript_.clear();
        aliyun_transcript_accumulator_.Reset();
        session_state_ = SessionState::kIdle;
        connection_state_ = ConnectionState::kDisconnected;
        websocket_ = nullptr;
        should_notify = !was_cancelled && had_active_session;
    }
    if (should_notify && on_error) on_error(message);
    return false;
}

bool AsrClientWin::SendAliyunRunTaskFrame(const std::string& task_id) {
    return SendAliyunTextFrameOrFail(AliyunRunTaskJson(config_, task_id), "start ASR session");
}

bool AsrClientWin::SendAliyunFinishTaskFrame(const std::string& task_id) {
    return SendAliyunTextFrameOrFail(AliyunFinishTaskJson(task_id), "finish ASR session");
}

void AsrClientWin::HandleAliyunResponse(std::span<const std::uint8_t> data) {
    const auto text = Utf8FromBytes(data);
    const auto event = JsonStringValue(text, "event");
    if (event == "task-started") {
        bool should_flush = false;
        {
            std::lock_guard lock(mutex_);
            if (session_state_ == SessionState::kStarting) {
                session_state_ = SessionState::kStreaming;
                should_flush = true;
            }
        }
        if (should_flush) FlushQueuedAudioChunks();
        return;
    }
    if (event == "result-generated") {
        auto transcript = AliyunSentenceText(text);
        if (transcript.empty()) return;
        const auto sentence_end = AliyunSentenceEnd(text);
        {
            std::lock_guard lock(mutex_);
            transcript = aliyun_transcript_accumulator_.Apply(transcript, sentence_end);
            latest_session_transcript_ = transcript;
        }
        if (on_partial) on_partial(transcript);
        return;
    }
    if (event == "task-finished") {
        std::string final_text;
        {
            std::lock_guard lock(mutex_);
            final_text = aliyun_transcript_accumulator_.CurrentText();
            if (final_text.empty()) final_text = latest_session_transcript_;
            current_session_id_.clear();
            latest_session_transcript_.clear();
            aliyun_transcript_accumulator_.Reset();
            emitted_definite_segment_keys_.clear();
            queued_audio_chunks_.clear();
            session_state_ = SessionState::kIdle;
        }
        if (on_final) on_final(final_text);
        return;
    }
    if (event == "task-failed") {
        FailReusableSession(AliyunErrorMessage(text));
    }
}

void AsrClientWin::SetLastStartError(std::string message) {
    std::lock_guard lock(mutex_);
    last_start_error_ = std::move(message);
}

void AsrClientWin::AddHeader(HINTERNET request, std::string_view name, std::string_view value) {
    const auto header = Utf16FromUtf8(std::string(name) + ": " + std::string(value) + "\r\n");
    WinHttpAddRequestHeaders(request, header.c_str(), static_cast<DWORD>(header.size()),
                             WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
}

std::string AsrClientWin::QueryStatusCode(HINTERNET request) {
    DWORD status_code = 0;
    DWORD size = sizeof(status_code);
    if (!WinHttpQueryHeaders(request,
                             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX,
                             &status_code,
                             &size,
                             WINHTTP_NO_HEADER_INDEX)) {
        return {};
    }
    return std::to_string(status_code);
}

std::string AsrClientWin::LastErrorText() {
    return std::to_string(GetLastError());
}

std::string AsrClientWin::GenerateSessionId() {
    std::array<std::uint8_t, 16> bytes{};
    if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        static std::atomic_uint counter = 0;
        const auto value = ++counter;
        char fallback[37]{};
        snprintf(fallback, sizeof(fallback), "voice-stick-windows-%08x", value);
        return fallback;
    }
    bytes[6] = static_cast<std::uint8_t>((bytes[6] & 0x0f) | 0x40);
    bytes[8] = static_cast<std::uint8_t>((bytes[8] & 0x3f) | 0x80);
    char out[37]{};
    snprintf(out, sizeof(out),
             "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             bytes[0], bytes[1], bytes[2], bytes[3],
             bytes[4], bytes[5], bytes[6], bytes[7],
             bytes[8], bytes[9], bytes[10], bytes[11],
             bytes[12], bytes[13], bytes[14], bytes[15]);
    return out;
}

void AsrClientWin::CloseHandles(HINTERNET session, HINTERNET connect,
                                HINTERNET request, HINTERNET websocket) {
    if (websocket) WinHttpCloseHandle(websocket);
    if (request) WinHttpCloseHandle(request);
    if (connect) WinHttpCloseHandle(connect);
    if (session) WinHttpCloseHandle(session);
}

} // namespace voicestick
