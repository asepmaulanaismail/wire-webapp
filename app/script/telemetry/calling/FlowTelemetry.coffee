#
# Wire
# Copyright (C) 2016 Wire Swiss GmbH
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see http://www.gnu.org/licenses/.
#

window.z ?= {}
z.telemetry ?= {}
z.telemetry.calling ?= {}

FLOW_TELEMETRY_CONFIG =
  STATS_CHECK_INTERVAL: 2000
  STATS_CHECK_TIMEOUT: 50
  MEDIA_CHECK_TIMEOUT: 5000

# Flow telemetry entity.
class z.telemetry.calling.FlowTelemetry
  ###
  Construct new flow telemetry entity.

  @param id [String] Flow ID
  @param remote_user_id [String] Remote user ID
  @param call_et [z.calling.Call] Call entity
  @param timings [z.telemetry.calling.CallSetupTimings] Timings of call setup steps
  ###
  constructor: (id, @remote_user_id, @call_et, timings) ->
    @logger = new z.util.Logger "z.telemetry.calling.FlowTelemetry (#{id})", z.config.LOGGER.OPTIONS

    @id = id
    @is_answer = false
    @peer_connection = undefined

    @timings = $.extend new z.telemetry.calling.CallSetupTimings(@id), timings?.get()
    @statistics = new z.telemetry.calling.ConnectionStats()

    @stats_poller = undefined


  ###############################################################################
  # External misc
  ###############################################################################

  ###
  Create flow status report for automation.
  @return [Object] Report
  ###
  create_automation_report: =>
    report = @create_report()
    report.meta.remote_user_id = @remote_user_id
    return report

  ###
  Create flow status report.
  @param passed_error [Error] Optional error to be added to report
  @return [Object] Report
  ###
  create_report: (passed_error) =>
    report =
      meta:
        browser_name: z.util.Environment.browser.name
        browser_version: z.util.Environment.browser.version
        flow_id: @id
        id: @call_et.id
        is_answer: @is_answer
        session_id: @call_et.session_id
      telemetry:
        statistics: @get_statistics()
        timings: @get_timings()

    if @peer_connection
      report.rtc_peer_connection =
        ice_connection_state: @peer_connection.iceConnectionState
        ice_gathering_state: @peer_connection.iceGatheringState
        signaling_state: @peer_connection.signalingState

      if @peer_connection.localDescription?
        rtc_peer_connection =
          local_SDP: @peer_connection.localDescription.sdp
          local_SDP_type: @peer_connection.localDescription.type
        $.extend report.rtc_peer_connection, rtc_peer_connection

      if @peer_connection.remoteDescription?
        rtc_peer_connection =
          remote_SDP: @peer_connection.remoteDescription.sdp
          remote_SDP_type: @peer_connection.remoteDescription.type
        $.extend report.rtc_peer_connection, rtc_peer_connection

    if passed_error
      report.error = passed_error

    return report

  ###
  Check stream for flowing bytes.

  @param media_type [z.media.MediaType] Media type of stream
  @param timeout [Number] Time in milliseconds since the check was scheduled
  @param attempt [Number] Attempt of stream check
  ###
  check_stream: (media_type, attempt = 1) =>
    stats = @statistics[media_type]
    if stats
      seconds = attempt * FLOW_TELEMETRY_CONFIG.MEDIA_CHECK_TIMEOUT / 1000
      if stats.bytes_received is 0 and stats.bytes_sent is 0
        @logger.warn "No '#{media_type}' flowing in either direction on stream after #{seconds} seconds"
      else if stats.bytes_received is 0
        @logger.warn "No incoming '#{media_type}' received on stream after #{seconds} seconds"
      else if stats.bytes_sent is 0
        @logger.warn "No outgoing '#{media_type}' sent on stream after #{seconds} seconds"
      else
        @logger.debug "Stream has '#{media_type}' flowing properly both ways"
    else
      if @is_answer
        @logger.info "Check '#{media_type}' statistics on stream delayed as we created this flow"
      else
        window.setTimeout =>
          @check_stream media_type, attempt++
        , FLOW_TELEMETRY_CONFIG.MEDIA_CHECK_TIMEOUT

  ###
  Schedule check of stream activity.
  @param media_type [z.media.MediaType] Type of checks to schedule
  ###
  schedule_check: (media_type) ->
    window.setTimeout =>
      @check_stream z.media.MediaType.AUDIO
      @check_stream z.media.MediaType.VIDEO if media_type is z.media.MediaType.VIDEO
    , FLOW_TELEMETRY_CONFIG.MEDIA_CHECK_TIMEOUT

  ###
  Set the PeerConnection on the telemetry.
  @param [RTCPeerConnection] PeerConnection to be used for telemetry
  ###
  set_peer_connection: (peer_connection) =>
    @peer_connection = peer_connection

  ###
  Update 'is_answer' status of flow.
  @param is_answer [Boolean] Is the flow an answer
  ###
  update_is_answer: (is_answer) =>
    @is_answer = is_answer
    @timings.is_answer = is_answer


  ###############################################################################
  # Statistics
  ###############################################################################

  # Flow connected.
  connected: =>
    @statistics.connected = Date.now()

  ###
  Return the statistics object.
  @return [z.telemetry.calling.stats.ConnectionStats] Flow statistics
  ###
  get_statistics: =>
    return @statistics

  # Update statics for the last time and then reset them and the polling interval.
  reset_statistics: =>
    return unless @stats_poller

    window.clearInterval @stats_poller
    @stats_poller = undefined

    @_update_statistics()
    .then =>
      @logger.info 'Network stats updated for the last time', @statistics
      amplify.publish z.event.WebApp.DEBUG.UPDATE_LAST_CALL_STATUS, @create_report()
      @statistics = {}

  ###
  Start statistics polling.
  @param ice_connection_state [RTCIceConnectionState] Current state of ICE connection
  ###
  start_statistics: =>
    return if @stats_poller

    # Track call stats
    @time_step z.telemetry.calling.CallSetupSteps.ICE_CONNECTION_CONNECTED
    $.extend @statistics, new z.telemetry.calling.ConnectionStats()
    @connected()

    # Report calling stats within specified interval
    window.setTimeout =>
      @_update_statistics()
      .then => @logger.info 'Network stats updated for the first time', @statistics
      .catch (error) => @logger.warn "Failed to update flow networks stats: #{error.message}"
    , FLOW_TELEMETRY_CONFIG.STATS_CHECK_TIMEOUT
    @stats_poller = window.setInterval =>
      @_update_statistics()
      .catch (error) => @logger.warn "Networks stats not updated: #{error.message}"
    , FLOW_TELEMETRY_CONFIG.STATS_CHECK_INTERVAL

  ###
  Get current statistics from PeerConnection.
  @private
  @return [Promise] Promise to be resolved when stats are returned
  ###
  _update_statistics: =>
    @peer_connection.getStats null
    .then (rtc_stats_report) =>
      connection_stats = new z.telemetry.calling.ConnectionStats()

      rtc_stats_report.forEach (report) =>
        switch report.type
          when z.calling.rtc.StatsType.CANDIDATE_PAIR
            connection_stats = @_update_from_candidate_pair report, rtc_stats_report, connection_stats
          when z.calling.rtc.StatsType.GOOGLE_CANDIDATE_PAIR
            connection_stats = @_update_peer_connection_bytes report, connection_stats
            connection_stats = @_update_from_google_candidate_pair report, rtc_stats_report, connection_stats
          when z.calling.rtc.StatsType.INBOUND_RTP
            connection_stats = @_update_peer_connection_bytes report, connection_stats
            connection_stats = @_update_from_inbound_rtp report, connection_stats
          when z.calling.rtc.StatsType.OUTBOUND_RTP
            connection_stats = @_update_peer_connection_bytes report, connection_stats
            connection_stats = @_update_from_outbound_rtp report, connection_stats
          when z.calling.rtc.StatsType.SSRC
            connection_stats = @_update_from_ssrc report, connection_stats

      _calc_rate = (key, timestamp, type) =>
        bytes = (connection_stats[key][type] - @statistics[key][type])
        time_span = (connection_stats.timestamp - timestamp)
        return window.parseInt 1000.0 * bytes / time_span, 10

      # Calculate bit rate since last update
      for key, value of connection_stats
        if _.isObject value
          connection_stats[key].bit_rate_mean_received = _calc_rate key, @statistics.connected, 'bytes_received'
          connection_stats[key].bit_rate_mean_sent = _calc_rate key, @statistics.connected, 'bytes_sent'
          connection_stats[key].bit_rate_current_received = _calc_rate key, @statistics.timestamp, 'bytes_received'
          connection_stats[key].bit_rate_current_sent = _calc_rate key, @statistics.timestamp, 'bytes_sent'

      $.extend @statistics, connection_stats
    .catch (error) =>
      @logger.warn 'Update of network stats for flow failed', error

  ###
  Update from z.calling.rtc.StatsType.CANDIDATE_PAIR report.

  @param report [Object] z.calling.rtc.StatsType.CANDIDATE_PAIR report
  @param rtc_stats_report [RTCStatsReport] Statistics report from PeerConnection
  @param connection_stats [z.telemetry.calling.ConnectionStats] Parsed flow statistics
  @return [z.telemetry.calling.ConnectionStats] updated_stats
  ###
  _update_from_candidate_pair: (report, rtc_stats_report, connection_stats) ->
    if report.selected
      connection_stats.peer_connection.local_candidate_type = rtc_stats_report.get(report.localCandidateId).candidateType
      connection_stats.peer_connection.remote_candidate_type = rtc_stats_report.get(report.remoteCandidateId).candidateType
    return connection_stats

  ###
  Update from z.calling.rtc.StatsType.GOOGLE_CANDIDATE_PAIR report.

  @param report [Object] z.calling.rtc.StatsType.GOOGLE_CANDIDATE_PAIR report
  @param rtc_stats_report [RTCStatsReport] Statistics report from PeerConnection
  @param connection_stats [z.telemetry.calling.ConnectionStats] Parsed flow statistics
  @return [z.telemetry.calling.ConnectionStats] updated_stats
  ###
  _update_from_google_candidate_pair: (report, rtc_stats_report, connection_stats) ->
    if report.googActiveConnection is 'true'
      connection_stats.peer_connection.round_trip_time = window.parseInt report.googRtt, 10
      connection_stats.peer_connection.local_candidate_type = rtc_stats_report.get(report.localCandidateId).candidateType
      connection_stats.peer_connection.remote_candidate_type = rtc_stats_report.get(report.remoteCandidateId).candidateType
    return connection_stats

  ###
  Update from z.calling.rtc.StatsType.INBOUND_RTP report.

  @param report [Object] z.calling.rtc.StatsType.INBOUND_RTP report
  @param connection_stats [z.telemetry.calling.ConnectionStats] Parsed flow statistics
  @return [z.telemetry.calling.ConnectionStats] updated_stats
  ###
  _update_from_inbound_rtp: (report, connection_stats) ->
    if report.mediaType in [z.media.MediaType.AUDIO, z.media.MediaType.VIDEO]
      connection_stats[report.mediaType].bytes_received += report.bytesReceived if report.bytesReceived
      connection_stats[report.mediaType].frame_rate_received = window.parseInt report.framerateMean, 10 if report.framerateMean
    return connection_stats

  ###
  Update from z.calling.rtc.StatsType.OUTBOUND_RTP report.

  @param report [Object] z.calling.rtc.StatsType.OUTBOUND_RTP report
  @param stats [z.telemetry.calling.ConnectionStats] Parsed flow statistics
  @return [z.telemetry.calling.ConnectionStats] updated_stats
  ###
  _update_from_outbound_rtp: (report, connection_stats) ->
    if report.mediaType in [z.media.MediaType.AUDIO, z.media.MediaType.VIDEO]
      connection_stats[report.mediaType].bytes_sent += report.bytesSent if report.bytesSent
      connection_stats[report.mediaType].frame_rate_sent = window.parseInt report.framerateMean, 10 if report.framerateMean
    return connection_stats

  ###
  Update from statistics report.

  @param report [Object] Statistics report
  @param stats [z.telemetry.calling.ConnectionStats] Parsed flow statistics
  @return [z.telemetry.calling.ConnectionStats] updated_stats
  ###
  _update_peer_connection_bytes: (report, connection_stats) ->
    connection_stats.peer_connection.bytes_received += window.parseInt report.bytesReceived, 10 if report.bytesReceived
    connection_stats.peer_connection.bytes_sent += window.parseInt report.bytesSent, 10 if report.bytesSent
    return connection_stats

  ###
  Update from z.calling.rtc.StatsType.SSRC report.

  @param report [Object] z.calling.rtc.StatsType.SSRC report
  @param stats [z.telemetry.calling.ConnectionStats] Parsed flow statistics
  @return [z.telemetry.calling.ConnectionStats] updated_stats
  ###
  _update_from_ssrc: (report, connection_stats) =>
    if report.codecImplementationName
      codec = "#{report.googCodecName} #{report.codecImplementationName}"
    else
      codec = report.googCodecName

    if report.audioOutputLevel
      stream_stats = connection_stats.audio
      stream_stats.volume_received = window.parseInt report.audioOutputLevel, 10
      stream_stats.codec_received = codec
    else if report.audioInputLevel
      stream_stats = connection_stats.audio
      stream_stats.volume_sent = window.parseInt report.audioInputLevel, 10
      stream_stats.codec_sent = codec
    else if @call_et.is_remote_screen_send() or @call_et.is_remote_video_send()
      stream_stats = connection_stats.video
      if report.googFrameHeightReceived
        stream_stats.frame_height_received = window.parseInt report.googFrameHeightReceived, 10
        stream_stats.frame_rate_received = window.parseInt report.googFrameRateReceived, 10
        stream_stats.frame_width_received = window.parseInt report.googFrameWidthReceived, 10
        stream_stats.codec_received = codec
      else if report.googFrameHeightSent
        stream_stats.frame_height_sent = window.parseInt report.googFrameHeightSent, 10
        stream_stats.frame_rate_sent = window.parseInt report.googFrameRateSent, 10 if report.googFrameRateSent
        stream_stats.frame_width_sent = window.parseInt report.googFrameWidthSent, 10 if report.googFrameWidthSent
        stream_stats.codec_sent = codec

    if stream_stats
      stream_stats.bytes_received += window.parseInt report.bytesReceived, 10 if report.bytesReceived
      stream_stats.bytes_received = connection_stats.peer_connection.bytes_received if stream_stats.bytes_received is 0
      stream_stats.bytes_sent += window.parseInt report.bytesSent, 10 if report.bytesSent
      stream_stats.bytes_sent = connection_stats.peer_connection.bytes_sent if stream_stats.bytes_sent is 0
      stream_stats.delay = window.parseInt report.googCurrentDelayMs, 10 if report.googCurrentDelayMs
      stream_stats.round_trip_time = window.parseInt report.googRtt, 10 if report.googRtt

    return connection_stats


  ###############################################################################
  # Timings
  ###############################################################################

  ###
  Return the step timings object.
  @return [z.telemetry.calling.CallSetupTimings] Flow statistics
  ###
  get_timings: =>
    return @timings.get()

  time_step: (step) =>
    @timings.time_step step


  ###############################################################################
  # Reporting & Logging
  ###############################################################################

  # Get full report.
  get_automation_report: =>
    return {
      report: @create_automation_report()
    }

  # Log the flow to the browser console.
  log_status: (participant_et) =>
    @logger.force_log "-- ID: #{@id}"

    if @remote_user isnt undefined
      @logger.force_log "-- Remote user: #{participant_et.user.name()} (#{participant_et.user.id})"

    @logger.force_log "-- User is connected: #{participant_et.is_connected()}"
    @logger.force_log "-- Flow is answer: #{@is_answer}"

    if @peer_connection
      @logger.force_log "-- ICE connection: #{@peer_connection.iceConnectionState}"
      @logger.force_log "-- ICE gathering: #{@peer_connection.iceGatheringState}"

    statistics = @get_statistics()
    if statistics
      # @note Types are 'none' if we cannot connect to the user (0 bytes flow)
      @logger.force_log 'PeerConnection network statistics', statistics
      @logger.force_log "-- Remote ICE candidate type: #{statistics.peer_connection.remote_candidate_type}"
      @logger.force_log "-- Local ICE candidate type: #{statistics.peer_connection.local_candidate_type}"
      # PeerConnection Stats
      for key, value of statistics
        if _.isObject value
          @logger.force_log "Statistics for '#{key}':"
          @logger.force_log "-- Bit rate received: #{value.bit_rate_received}"
          @logger.force_log "-- Bit rate sent: #{value.bit_rate_sent}"
          @logger.force_log "-- Bytes sent: #{value.bytes_sent}"
          @logger.force_log "-- Bytes received: #{value.bytes_received}"
          @logger.force_log "-- Rtt: #{value.rtt}"
          media_types = [z.media.MediaType.AUDIO, z.media.MediaType.VIDEO]
          if z.util.Environment.browser.chrome and key in media_types
            @logger.force_log "-- Codec received: #{value.codec_received}"
            @logger.force_log "-- Codec sent: #{value.codec_sent}"
            @logger.force_log "-- Delay in ms: #{value.delay}"
          if key is z.media.MediaType.VIDEO
            @logger.force_log "-- Frame rate received: #{value.frame_rate_received}"
            @logger.force_log "-- Frame rate sent: #{value.frame_rate_sent}"
            continue if not z.util.Environment.browser.chrome
            received_resolution = "#{value.frame_width_received}x#{value.frame_height_received}"
            sent_resolution = "#{value.frame_width_sent}x#{value.frame_height_sent}"
            @logger.force_log "-- Frame resolution received: #{received_resolution}"
            @logger.force_log "-- Frame resolution sent: #{sent_resolution}"
          else if key is z.media.MediaType.AUDIO
            @logger.force_log "-- Volume received: #{value.volume_received}"
            @logger.force_log "-- Volume sent: #{value.volume_sent}"

  log_timings: =>
    @timings.log()

  ###
  Report an error to Raygun.
  @param description [String] Error description
  @param passed_error [Object] Error passed into the report
  @param payload [Object] Additional payload for the custom data
  ###
  report_error: (description, passed_error, payload) =>
    custom_data = @create_report()
    raygun_error = new Error description

    if passed_error
      custom_data.error = passed_error
      raygun_error.stack = passed_error.stack

    if payload
      custom_data.payload = payload

    @logger.error description, custom_data
    Raygun.send raygun_error, custom_data

  report_status: =>
    custom_data = @create_report()
    @logger.info 'Created flow status for call failure report', custom_data
    return custom_data

  report_timings: =>
    custom_data = @timings.log()
    Raygun.send new Error('Call setup step timings'), custom_data
    @logger.info "Reported setup step timings of flow id '#{@id}' for call analysis", custom_data
