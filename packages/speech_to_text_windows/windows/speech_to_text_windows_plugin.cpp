#include "speech_to_text_windows_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <sapi.h>
#include <optional>
#include <string>

namespace speech_to_text_windows {

namespace {

// SAPI posts this to the app window when speech events are ready, so they
// are handled on the UI thread (the only thread allowed to talk to Flutter).
constexpr UINT kSpeechMessage = WM_APP + 0x5A1;
// Timer that ends a recording shortly after "stop", so last words land.
constexpr UINT_PTR kStopTimer = 0x5A1;
constexpr UINT kStopGraceMs = 700;

std::string ToUtf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(),
                                 nullptr, 0, nullptr, nullptr);
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &out[0], size,
                      nullptr, nullptr);
  return out;
}

std::string JsonEscape(const std::string& s) {
  std::string out;
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += (char)c;
        }
    }
  }
  return out;
}

// Frees whatever an SPEVENT carries (what CSpEvent::Clear does).
void ClearEvent(SPEVENT& ev) {
  switch (ev.elParamType) {
    case SPET_LPARAM_IS_OBJECT:
      if (ev.lParam) reinterpret_cast<IUnknown*>(ev.lParam)->Release();
      break;
    case SPET_LPARAM_IS_POINTER:
    case SPET_LPARAM_IS_STRING:
      CoTaskMemFree(reinterpret_cast<void*>(ev.lParam));
      break;
    default:
      break;
  }
  ev.lParam = 0;
}

template <typename T>
void SafeRelease(T*& p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

}  // namespace

void SpeechToTextWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<SpeechToTextWindowsPlugin>();
  plugin->m_registrar = registrar;
  plugin->m_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "speech_to_text_windows",
          &flutter::StandardMethodCodec::GetInstance());

  auto* p = plugin.get();
  p->m_channel->SetMethodCallHandler(
      [p](const auto& call, auto result) {
        p->HandleMethodCall(call, std::move(result));
      });
  p->m_procId = registrar->RegisterTopLevelWindowProcDelegate(
      [p](HWND hwnd, UINT msg, WPARAM wparam,
          LPARAM) -> std::optional<LRESULT> {
        if (msg == kSpeechMessage) {
          p->DrainEvents();
          return 0;
        }
        if (msg == WM_TIMER && wparam == kStopTimer) {
          KillTimer(hwnd, kStopTimer);
          p->FinishStop();
          return 0;
        }
        return std::nullopt;
      });

  registrar->AddPlugin(std::move(plugin));
}

SpeechToTextWindowsPlugin::SpeechToTextWindowsPlugin() {}

SpeechToTextWindowsPlugin::~SpeechToTextWindowsPlugin() {
  if (m_registrar && m_procId) {
    m_registrar->UnregisterTopLevelWindowProcDelegate(m_procId);
  }
  if (m_cpRecoGrammar) m_cpRecoGrammar->SetDictationState(SPRS_INACTIVE);
  SafeRelease(m_cpRecoGrammar);
  SafeRelease(m_cpRecoContext);
  SafeRelease(m_cpRecognizer);
  SafeRelease(m_cpAudio);
}

HWND SpeechToTextWindowsPlugin::RootWindow() {
  auto* view = m_registrar ? m_registrar->GetView() : nullptr;
  HWND hwnd = view ? view->GetNativeWindow() : nullptr;
  return hwnd ? GetAncestor(hwnd, GA_ROOT) : nullptr;
}

void SpeechToTextWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& name = method_call.method_name();
  if (name == "hasPermission") {
    result->Success(flutter::EncodableValue(true));
  } else if (name == "initialize") {
    result->Success(flutter::EncodableValue(Initialize()));
  } else if (name == "listen") {
    result->Success(flutter::EncodableValue(Listen()));
  } else if (name == "stop") {
    Stop();
    result->Success();
  } else if (name == "cancel") {
    // Cancel = stop now, nothing more is wanted.
    if (HWND root = RootWindow()) KillTimer(root, kStopTimer);
    FinishStop();
    result->Success();
  } else if (name == "locales") {
    flutter::EncodableList locales;
    locales.push_back(flutter::EncodableValue("en-US:English (United States)"));
    result->Success(flutter::EncodableValue(locales));
  } else {
    result->NotImplemented();
  }
}

bool SpeechToTextWindowsPlugin::Initialize() {
  if (m_initialized) return true;
  HWND root = RootWindow();
  if (!root) return false;

  HRESULT hr = CoCreateInstance(CLSID_SpInprocRecognizer, nullptr,
                                CLSCTX_INPROC_SERVER, IID_ISpRecognizer,
                                (void**)&m_cpRecognizer);
  if (SUCCEEDED(hr)) {
    hr = CoCreateInstance(CLSID_SpMMAudioIn, nullptr, CLSCTX_INPROC_SERVER,
                          IID_ISpAudio, (void**)&m_cpAudio);
  }
  if (SUCCEEDED(hr)) hr = m_cpRecognizer->SetInput(m_cpAudio, TRUE);
  if (SUCCEEDED(hr)) hr = m_cpRecognizer->CreateRecoContext(&m_cpRecoContext);
  if (SUCCEEDED(hr)) {
    // Live words (hypotheses) as well as finished phrases.
    const ULONGLONG interest = SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_HYPOTHESIS);
    hr = m_cpRecoContext->SetInterest(interest, interest);
  }
  if (SUCCEEDED(hr)) {
    hr = m_cpRecoContext->SetNotifyWindowMessage(root, kSpeechMessage, 0, 0);
  }
  if (SUCCEEDED(hr)) hr = m_cpRecoContext->CreateGrammar(0, &m_cpRecoGrammar);
  if (SUCCEEDED(hr)) hr = m_cpRecoGrammar->LoadDictation(nullptr, SPLO_STATIC);
  if (FAILED(hr)) {
    SafeRelease(m_cpRecoGrammar);
    SafeRelease(m_cpRecoContext);
    SafeRelease(m_cpRecognizer);
    SafeRelease(m_cpAudio);
    return false;
  }
  m_initialized = true;
  return true;
}

bool SpeechToTextWindowsPlugin::Listen() {
  if (!m_initialized) return false;
  if (HWND root = RootWindow()) KillTimer(root, kStopTimer);
  if (m_listening) FinishStop();  // a new recording replaces the old one
  DrainEvents();                  // throw away leftovers from before
  m_committed.clear();
  m_hypothesis.clear();
  m_stopping = false;
  if (FAILED(m_cpRecoGrammar->SetDictationState(SPRS_ACTIVE))) return false;
  m_listening = true;
  SendStatus("listening");
  return true;
}

void SpeechToTextWindowsPlugin::Stop() {
  if (!m_listening || m_stopping) return;
  m_stopping = true;
  HWND root = RootWindow();
  if (!root || !SetTimer(root, kStopTimer, kStopGraceMs, nullptr)) {
    FinishStop();
  }
}

void SpeechToTextWindowsPlugin::FinishStop() {
  if (!m_listening) return;
  DrainEvents();  // last words already recognised
  m_cpRecoGrammar->SetDictationState(SPRS_INACTIVE);
  m_listening = false;
  m_stopping = false;
  SendStatus("notListening");
  SendStatus("done");
}

void SpeechToTextWindowsPlugin::DrainEvents() {
  if (!m_cpRecoContext) return;
  SPEVENT ev;
  ULONG fetched = 0;
  while (SUCCEEDED(m_cpRecoContext->GetEvents(1, &ev, &fetched)) &&
         fetched == 1) {
    const bool phrase = ev.eEventId == SPEI_RECOGNITION;
    if (m_listening && (phrase || ev.eEventId == SPEI_HYPOTHESIS) &&
        ev.elParamType == SPET_LPARAM_IS_OBJECT && ev.lParam) {
      auto* r = reinterpret_cast<ISpRecoResult*>(ev.lParam);
      LPWSTR text = nullptr;
      if (SUCCEEDED(r->GetText(SP_GETWHOLEPHRASE, SP_GETWHOLEPHRASE, TRUE,
                               &text, nullptr)) &&
          text) {
        std::wstring words(text);
        CoTaskMemFree(text);
        if (phrase) {
          if (!words.empty()) {
            if (!m_committed.empty()) m_committed += L" ";
            m_committed += words;
          }
          m_hypothesis.clear();
        } else {
          m_hypothesis = words;
        }
        std::wstring all = m_committed;
        if (!m_hypothesis.empty()) {
          if (!all.empty()) all += L" ";
          all += m_hypothesis;
        }
        SendText(all);
      }
    }
    ClearEvent(ev);
  }
}

void SpeechToTextWindowsPlugin::SendText(const std::wstring& text) {
  if (!m_channel || text.empty()) return;
  // Always "partial": the whole recording so far. The app decides when it
  // ends (let go / tap / silence) and the plugin's stop turns it final.
  const std::string words = JsonEscape(ToUtf8(text));
  const std::string json = "{\"alternates\":[{\"recognizedWords\":\"" +
                           words + "\",\"confidence\":0.85}],"
                           "\"resultType\":0}";
  m_channel->InvokeMethod("textRecognition",
                          std::make_unique<flutter::EncodableValue>(json));
}

void SpeechToTextWindowsPlugin::SendStatus(const std::string& status) {
  if (!m_channel) return;
  m_channel->InvokeMethod("notifyStatus",
                          std::make_unique<flutter::EncodableValue>(status));
}

}  // namespace speech_to_text_windows
