defmodule JX.ParticipantPlugins.GoogleMeet do
  @moduledoc """
  Metadata for the bundled Google Meet participant plugin.
  """

  @doc """
  Returns the stable plugin descriptor used by CLI and JSON surfaces.
  """
  def plugin do
    %{
      id: "google_meet",
      name: "Google Meet",
      surface: "meet",
      bundled: true,
      status: "available",
      auth: %{
        kind: "personal-google-oauth",
        default_profile: "personal",
        scopes: JX.GoogleMeet.default_scopes(),
        artifact_scopes: JX.GoogleMeet.artifact_scopes()
      },
      realtime: %{
        browser: "browser-agent",
        fallback_browser: "chrome-cdp",
        audio_bridge: "browser-agent",
        fallback_audio_bridge: "twilio-media-streams",
        voice_loop: "openclaw-agent-consult",
        providers: JX.GoogleMeet.realtime_providers(),
        supports_caption_watch: true,
        supports_paired_chrome_node: true,
        supports_recovery: true
      },
      exports: %{
        formats: JX.GoogleMeet.export_formats(),
        directory: "session artifact directory or ~/.jx/meet/<session-id>/artifacts"
      },
      constraints: [
        "Google Meet REST APIs manage spaces and artifacts; participant join uses a browser agent with Chrome/CDP fallback.",
        "Live audio capture and speech output require explicit operator approval before audio is sent to providers or back into Meet.",
        "Twilio bidirectional streams use Connect/Stream and only receive the inbound track.",
        "Restricted Google Drive scopes may require Google verification before production use."
      ]
    }
  end
end
