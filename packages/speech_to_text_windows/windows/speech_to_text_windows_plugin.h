#ifndef FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <sapi.h>
#include <memory>
#include <string>

namespace speech_to_text_windows {

// Thinklet fork: SAPI events arrive as a window message on the UI thread
// (no background thread), words stream live (hypotheses), and every phrase
// of one recording is kept instead of ending at the first pause.
class SpeechToTextWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  SpeechToTextWindowsPlugin();
  virtual ~SpeechToTextWindowsPlugin();

  SpeechToTextWindowsPlugin(const SpeechToTextWindowsPlugin&) = delete;
  SpeechToTextWindowsPlugin& operator=(const SpeechToTextWindowsPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool Initialize();
  bool Listen();
  void Stop();        // keeps listening briefly so the last words land
  void FinishStop();  // really stops
  void DrainEvents();
  HWND RootWindow();

  void SendText(const std::wstring& text);
  void SendStatus(const std::string& status);

  ISpRecognizer* m_cpRecognizer = nullptr;
  ISpRecoContext* m_cpRecoContext = nullptr;
  ISpRecoGrammar* m_cpRecoGrammar = nullptr;
  ISpAudio* m_cpAudio = nullptr;

  bool m_initialized = false;
  bool m_listening = false;
  bool m_stopping = false;
  std::wstring m_committed;   // finished phrases of this recording
  std::wstring m_hypothesis;  // the phrase being spoken right now

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> m_channel;
  flutter::PluginRegistrarWindows* m_registrar = nullptr;
  int m_procId = 0;
};

}  // namespace speech_to_text_windows

#endif  // FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_
