CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "transcriptions" ("id" TEXT PRIMARY KEY NOT NULL, "text" TEXT NOT NULL, "created_at" INTEGER NOT NULL, "delivery_state" TEXT NOT NULL, "recovery_state" TEXT NOT NULL, "quality" TEXT NOT NULL, "stop_reason" TEXT NOT NULL, "target_bundle_id" TEXT, "attempt_id" TEXT, "attempt_started_at" INTEGER, "revision" INTEGER NOT NULL DEFAULT 0, "rewrite_state" TEXT NOT NULL CHECK (rewrite_state IN ('not_requested','pending','succeeded','failed','cancelled','timed_out')) DEFAULT 'not_requested', "delivered_source" TEXT CHECK (delivered_source IS NULL OR delivered_source IN ('faithful','rewrite')), "delivered_rewrite_attempt_id" TEXT REFERENCES "rewrite_attempts"("id") ON DELETE SET NULL, recognition_path TEXT NOT NULL DEFAULT 'local'
  CHECK (recognition_path IN ('local', 'server', 'local_after_server_failure')), server_failure TEXT
  CHECK (server_failure IS NULL OR length(server_failure) <= 32), input_device_name TEXT
  CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128), input_device_kind TEXT
  CHECK (input_device_kind IS NULL OR input_device_kind IN
    ('builtIn','usb','bluetooth','iPhone','virtual','other','systemDefault')), CHECK (length(cast(text as blob)) BETWEEN 1 AND 65536), CHECK (target_bundle_id IS NULL OR length(cast(target_bundle_id as blob)) <= 255), CHECK (revision >= 0), CHECK (delivery_state IN ('not_attempted','attempting','confirmed','not_inserted','uncertain')), CHECK (recovery_state IN ('needs_review','resolved')), CHECK (quality IN ('complete','duration_limited','incomplete')), CHECK (stop_reason IN ('key_release','duration_limit','cancel','overflow','device_loss','permission_revoked','sleep','failure')));
CREATE TABLE "history_usage" ("id" INTEGER PRIMARY KEY CHECK (id = 1), "row_count" INTEGER NOT NULL CHECK (row_count >= 0), "payload_bytes" INTEGER NOT NULL CHECK (payload_bytes >= 0));
CREATE TABLE "transcription_quality" ("transcription_id" TEXT PRIMARY KEY NOT NULL REFERENCES "transcriptions"("id") ON DELETE CASCADE, "schema_version" INTEGER NOT NULL CHECK (schema_version = 1), "detail_json" TEXT NOT NULL CHECK (length(cast(detail_json AS blob)) <= 262144), "content_hash" TEXT NOT NULL CHECK (length(content_hash) = 64));
CREATE TABLE "vocabulary_entries" ("id" TEXT PRIMARY KEY NOT NULL, "canonical_text" TEXT NOT NULL CHECK (length(cast(canonical_text AS blob)) BETWEEN 1 AND 256), "aliases_json" TEXT NOT NULL, "enabled" BOOLEAN NOT NULL, "learned_at" INTEGER CHECK (learned_at IS NULL OR learned_at >= 0));
CREATE TABLE "vocabulary_state" ("id" INTEGER PRIMARY KEY CHECK (id = 1), "schema_version" INTEGER NOT NULL CHECK (schema_version = 1), "revision" INTEGER NOT NULL CHECK (revision >= 0), "content_hash" TEXT NOT NULL CHECK (length(content_hash) = 64), "payload_bytes" INTEGER NOT NULL CHECK (payload_bytes BETWEEN 0 AND 1048576));
CREATE TABLE "meetings" ("id" TEXT PRIMARY KEY NOT NULL, "state" TEXT NOT NULL CHECK (state IN ('created','preparing','recording','paused','finalizing','completed','interrupted','failed')), "title" TEXT CHECK (title IS NULL OR length(cast(title AS blob)) BETWEEN 1 AND 256), "created_at" INTEGER NOT NULL, "started_at" INTEGER, "stopped_at" INTEGER, "completed_at" INTEGER, "wall_clock_ms" INTEGER NOT NULL CHECK (wall_clock_ms >= 0) DEFAULT 0, "recorded_ms" INTEGER NOT NULL CHECK (recorded_ms >= 0) DEFAULT 0, "finalization_stage" TEXT CHECK (finalization_stage IS NULL OR finalization_stage IN ('none','mic','system','both')), "failure_reason" TEXT CHECK (failure_reason IS NULL OR failure_reason IN ('not_running_at_last_state','storage_write_failed','storage_unavailable','encoder_failed','permission_revoked','device_lost','stream_stopped','both_sources_failed','record_missing','file_missing','segment_open_failed','unrecoverable_media')), "failure_detail" TEXT CHECK (failure_detail IS NULL OR length(cast(failure_detail AS blob)) <= 512), "updated_at" INTEGER NOT NULL, "revision" INTEGER NOT NULL CHECK (revision >= 0) DEFAULT 0, language TEXT
  CHECK(language IS NULL OR language IN ('automatic','slovak','czech','english')), run_locally INTEGER NOT NULL DEFAULT 0 CHECK (run_locally IN (0,1)), origin TEXT NOT NULL DEFAULT 'local'
  CHECK (origin IN ('local','iphone')), CHECK (failure_reason IS NULL OR state IN ('interrupted','failed')));
CREATE TABLE "meeting_tracks" ("id" TEXT PRIMARY KEY NOT NULL, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "type" TEXT NOT NULL CHECK (type IN ('microphone','system')), "codec" TEXT NOT NULL CHECK (codec = 'aac_lc'), "container" TEXT NOT NULL CHECK (container = 'adts'), "sample_rate" INTEGER NOT NULL CHECK (sample_rate > 0), "channel_count" INTEGER NOT NULL CHECK (channel_count IN (1,2)), "bitrate" INTEGER NOT NULL CHECK (bitrate > 0), "health" TEXT NOT NULL CHECK (health IN ('healthy','failed','finalized','unrecoverable')), "failure_reason" TEXT CHECK (failure_reason IS NULL OR failure_reason IN ('not_running_at_last_state','storage_write_failed','storage_unavailable','encoder_failed','permission_revoked','device_lost','stream_stopped','both_sources_failed','record_missing','file_missing','segment_open_failed','unrecoverable_media')), "failed_at" INTEGER, "total_duration_ms" INTEGER NOT NULL CHECK (total_duration_ms >= 0) DEFAULT 0, "total_bytes" INTEGER NOT NULL CHECK (total_bytes >= 0) DEFAULT 0, "duration_warning" INTEGER NOT NULL CHECK (duration_warning IN (0,1)) DEFAULT 0, "dropped_frames" INTEGER NOT NULL CHECK (dropped_frames >= 0) DEFAULT 0, CHECK ((failure_reason IS NOT NULL) = (health IN ('failed','unrecoverable'))));
CREATE TABLE "meeting_pauses" ("id" TEXT PRIMARY KEY NOT NULL, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "started_at" INTEGER NOT NULL, "ended_at" INTEGER CHECK (ended_at IS NULL OR ended_at >= started_at), "reason" TEXT NOT NULL CHECK (reason IN ('user','system_sleep')), "closed_by" TEXT CHECK (closed_by IS NULL OR closed_by IN ('resume','stop','reconciliation')), CHECK ((ended_at IS NULL) = (closed_by IS NULL)));
CREATE TABLE "meeting_notes" ("meeting_id" TEXT PRIMARY KEY NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "text" TEXT NOT NULL CHECK (length(cast(text AS blob)) <= 1048576), "author" TEXT NOT NULL CHECK (author = 'user'), "updated_at" INTEGER NOT NULL, "revision" INTEGER NOT NULL CHECK (revision >= 0) DEFAULT 0);
CREATE TABLE "meeting_recovery_outcomes" ("id" TEXT PRIMARY KEY NOT NULL, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "ran_at" INTEGER NOT NULL, "found_state" TEXT NOT NULL CHECK (found_state IN ('created','preparing','recording','paused','finalizing','completed','interrupted','failed')), "found_stage" TEXT CHECK (found_stage IS NULL OR found_stage IN ('none','mic','system','both')), "segments_recovered" INTEGER NOT NULL CHECK (segments_recovered >= 0) DEFAULT 0, "segments_unrecoverable" INTEGER NOT NULL CHECK (segments_unrecoverable >= 0) DEFAULT 0, "segments_missing" INTEGER NOT NULL CHECK (segments_missing >= 0) DEFAULT 0, "pause_closed" INTEGER NOT NULL CHECK (pause_closed IN (0,1)) DEFAULT 0, "bytes_truncated" INTEGER NOT NULL CHECK (bytes_truncated >= 0) DEFAULT 0, "summary" TEXT NOT NULL CHECK (length(cast(summary AS blob)) <= 512));
CREATE TABLE meeting_transcriptions (
  meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  state TEXT NOT NULL CHECK(state IN ('not_requested','pending','live','finalizing','final','failed','interrupted')),
  live_requested INTEGER NOT NULL CHECK(live_requested IN (0,1)),
  live_state TEXT CHECK(live_state IN ('live','catching_up','degraded','suspended','stopped')),
  pass_id TEXT, pass_kind TEXT CHECK(pass_kind IN ('live','final')),
  engine TEXT, model_id TEXT, model_revision TEXT,
  model_manifest_hash TEXT CHECK(model_manifest_hash IS NULL OR (length(model_manifest_hash)=64 AND model_manifest_hash NOT GLOB '*[^0-9a-fA-F]*')),
  pipeline_version TEXT CHECK(length(CAST(pipeline_version AS BLOB))<=256), planner_version TEXT,
  vocabulary_revision INTEGER CHECK(vocabulary_revision>=0),
  vocabulary_hash TEXT CHECK(vocabulary_hash IS NULL OR (length(vocabulary_hash)=64 AND vocabulary_hash NOT GLOB '*[^0-9a-fA-F]*')),
  analysis_descriptor_json TEXT CHECK(length(CAST(analysis_descriptor_json AS BLOB))<=16384),
  started_at INTEGER, live_started_at INTEGER, finalization_started_at INTEGER, finalized_at INTEGER,
  progress_sequence INTEGER CHECK(progress_sequence>=1), progress_sample INTEGER CHECK(progress_sample>=0),
  covered_ms INTEGER NOT NULL DEFAULT 0 CHECK(covered_ms>=0),
  recorded_ms_at_pass INTEGER NOT NULL DEFAULT 0 CHECK(recorded_ms_at_pass>=0),
  replaced_provisional_count INTEGER NOT NULL DEFAULT 0 CHECK(replaced_provisional_count>=0),
  model_reload_count INTEGER NOT NULL DEFAULT 0 CHECK(model_reload_count>=0),
  failure_category TEXT CHECK(failure_category IN ('model_unavailable','model_provisioning','model_load_failure','audio_decode_failure','analysis_stream_failure','runtime_failure','finalization_interrupted','persistence_failure','persistence_capacity')),
  failure_detail TEXT CHECK(length(CAST(failure_detail AS BLOB))<=512),
  segment_count INTEGER NOT NULL DEFAULT 0 CHECK(segment_count>=0),
  text_bytes INTEGER NOT NULL DEFAULT 0 CHECK(text_bytes>=0),
  updated_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0), inference_path TEXT NOT NULL DEFAULT 'local'
  CHECK (inference_path IN ('local','server','local_after_server_failure')), server_failure TEXT
  CHECK (server_failure IS NULL OR (inference_path != 'server' AND server_failure IN ('unreachable','busy','worker_unavailable','not_offered','user_ran_locally'))),
  CHECK(live_state IS NULL OR state='live'),
  CHECK((failure_category IS NOT NULL)=(state IN ('failed','interrupted')))
);
CREATE TABLE transcript_segments (
  id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  pass_id TEXT NOT NULL, finality TEXT NOT NULL CHECK(finality IN ('provisional','final')),
  ordinal INTEGER NOT NULL CHECK(ordinal>=0), stretch_sequence INTEGER NOT NULL CHECK(stretch_sequence>=1),
  start_ms INTEGER NOT NULL CHECK(start_ms>=0), end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
  window_index INTEGER NOT NULL CHECK(window_index>=0), timing_basis TEXT NOT NULL CHECK(timing_basis IN ('word','window')),
  raw_text TEXT NOT NULL CHECK(length(CAST(raw_text AS BLOB))<=4096),
  assembled_text TEXT NOT NULL CHECK(length(CAST(assembled_text AS BLOB))<=4096),
  normalized_text TEXT NOT NULL CHECK(length(CAST(normalized_text AS BLOB))<=4096),
  engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
  pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB))<=256),
  analysis_tracks TEXT NOT NULL CHECK(analysis_tracks IN ('mic','system','both')),
  speaker TEXT NOT NULL DEFAULT 'unassigned' CHECK(speaker='unassigned'), created_at INTEGER NOT NULL,
  UNIQUE(meeting_id,pass_id,ordinal)
);
CREATE TABLE transcript_usage (
  id INTEGER PRIMARY KEY CHECK(id=1), text_bytes INTEGER NOT NULL CHECK(text_bytes>=0),
  segment_rows INTEGER NOT NULL CHECK(segment_rows>=0), schema_version INTEGER NOT NULL CHECK(schema_version=1)
);
CREATE TABLE diarization_runs (
  id TEXT PRIMARY KEY NOT NULL,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  transcript_pass_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','running','succeeded','failed','interrupted','superseded')),
  "trigger" TEXT NOT NULL CHECK("trigger" IN ('automatic','manual','retry','in_room_change')),
  in_room INTEGER NOT NULL CHECK(in_room IN (0,1)),
  engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
  model_manifest_hash TEXT NOT NULL CHECK(length(model_manifest_hash)=64 AND model_manifest_hash NOT GLOB '*[^0-9a-f]*'),
  pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB)) BETWEEN 1 AND 256),
  created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
  failure_category TEXT CHECK(failure_category IS NULL OR failure_category IN ('model_unavailable','os_unsupported','model_load_failure','audio_missing','audio_decode_failure','runtime_failure','transcript_changed','persistence_failure','persistence_capacity','interrupted')),
  failure_detail TEXT CHECK(failure_detail IS NULL OR length(CAST(failure_detail AS BLOB))<=512),
  inferred_speaker_count INTEGER NOT NULL DEFAULT 0 CHECK(inferred_speaker_count>=0),
  audio_ms INTEGER NOT NULL DEFAULT 0 CHECK(audio_ms>=0),
  window_count INTEGER NOT NULL DEFAULT 0 CHECK(window_count>=0),
  turn_count INTEGER NOT NULL DEFAULT 0 CHECK(turn_count>=0),
  overlap_turn_count INTEGER NOT NULL DEFAULT 0 CHECK(overlap_turn_count>=0),
  unknown_count INTEGER NOT NULL DEFAULT 0 CHECK(unknown_count>=0),
  ambiguous_count INTEGER NOT NULL DEFAULT 0 CHECK(ambiguous_count>=0),
  uncertain_reconciliations INTEGER NOT NULL DEFAULT 0 CHECK(uncertain_reconciliations>=0),
  overflow_turns INTEGER NOT NULL DEFAULT 0 CHECK(overflow_turns>=0),
  preemption_count INTEGER NOT NULL DEFAULT 0 CHECK(preemption_count>=0), inference_path TEXT NOT NULL DEFAULT 'local'
  CHECK (inference_path IN ('local','server','local_after_server_failure')), server_failure TEXT
  CHECK (server_failure IS NULL OR (inference_path != 'server' AND server_failure IN ('unreachable','busy','worker_unavailable','not_offered','user_ran_locally'))),
  CHECK((failure_category IS NOT NULL) = (state IN ('failed','interrupted')))
);
CREATE TABLE meeting_diarization (
  meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  accepted_run_id TEXT REFERENCES diarization_runs(id) ON DELETE SET NULL,
  current_run_id TEXT REFERENCES diarization_runs(id) ON DELETE SET NULL,
  in_room INTEGER NOT NULL DEFAULT 0 CHECK(in_room IN (0,1)),
  updated_at INTEGER NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0)
);
CREATE TABLE meeting_speakers (
  id TEXT PRIMARY KEY NOT NULL,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES diarization_runs(id) ON DELETE CASCADE,
  cluster_key INTEGER NOT NULL CHECK(cluster_key>=0),
  source TEXT NOT NULL CHECK(source IN ('local','remote')),
  track TEXT CHECK(track IS NULL OR track IN ('microphone','system')),
  origin TEXT NOT NULL CHECK(origin IN ('engine','manual')),
  label_ordinal INTEGER NOT NULL DEFAULT 1 CHECK(label_ordinal>=1),
  color_index INTEGER NOT NULL DEFAULT 0 CHECK(color_index BETWEEN 0 AND 7),
  display_name TEXT CHECK(display_name IS NULL OR (
    length(display_name) BETWEEN 1 AND 80 AND display_name = trim(display_name)
    AND display_name NOT GLOB ('*[' || char(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,127) || ']*'))),
  merged_into TEXT REFERENCES meeting_speakers(id) ON DELETE SET NULL,
  reconciliation TEXT NOT NULL DEFAULT 'confident' CHECK(reconciliation IN ('confident','uncertain')),
  first_ms INTEGER NOT NULL DEFAULT 0 CHECK(first_ms>=0),
  speech_ms INTEGER NOT NULL DEFAULT 0 CHECK(speech_ms>=0),
  engine_quality REAL,
  CHECK((origin = 'manual') = (run_id IS NULL)),
  CHECK((origin = 'manual') = (track IS NULL)),
  CHECK(merged_into IS NULL OR merged_into <> id)
);
CREATE TABLE speaker_turns (
  id INTEGER PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
  speaker_id TEXT REFERENCES meeting_speakers(id) ON DELETE CASCADE,
  track TEXT NOT NULL CHECK(track IN ('microphone','system')),
  start_ms INTEGER NOT NULL CHECK(start_ms>=0),
  end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
  engine_quality REAL,
  overlapped INTEGER NOT NULL DEFAULT 0 CHECK(overlapped IN (0,1))
);
CREATE TABLE speaker_assignments (
  run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
  segment_id TEXT NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
  auto_kind TEXT NOT NULL CHECK(auto_kind IN ('speaker','unknown','ambiguous')),
  auto_speaker_id TEXT REFERENCES meeting_speakers(id),
  top_speaker_id TEXT, second_speaker_id TEXT,
  top_coverage REAL NOT NULL DEFAULT 0 CHECK(top_coverage BETWEEN 0 AND 1),
  second_coverage REAL NOT NULL DEFAULT 0 CHECK(second_coverage BETWEEN 0 AND 1),
  manual_kind TEXT CHECK(manual_kind IS NULL OR manual_kind IN ('speaker','unknown')),
  manual_speaker_id TEXT REFERENCES meeting_speakers(id),
  manual_at INTEGER,
  PRIMARY KEY(run_id, segment_id),
  CHECK((auto_speaker_id IS NOT NULL) = (auto_kind = 'speaker')),
  CHECK((manual_speaker_id IS NOT NULL) = (manual_kind IS 'speaker')),
  CHECK((manual_at IS NOT NULL) = (manual_kind IS NOT NULL))
) WITHOUT ROWID;
CREATE TABLE speaker_corrections (
  id TEXT PRIMARY KEY NOT NULL,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('rename','merge','unmerge','segment')),
  speaker_id TEXT, target_speaker_id TEXT,
  segment_id TEXT CHECK((segment_id IS NOT NULL) = (kind = 'segment')),
  previous_value TEXT CHECK(previous_value IS NULL OR length(previous_value)<=80),
  new_value TEXT CHECK(new_value IS NULL OR length(new_value)<=80),
  needs_review INTEGER NOT NULL DEFAULT 0 CHECK(needs_review IN (0,1)),
  created_at INTEGER NOT NULL, undone_at INTEGER
);
CREATE TABLE known_speakers (
  id TEXT PRIMARY KEY NOT NULL,
  display_name TEXT NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80 AND display_name = trim(display_name)
AND display_name NOT GLOB ('*[' || char(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,127) || ']*')),
  is_local_user INTEGER NOT NULL DEFAULT 0 CHECK(is_local_user IN (0,1)),
  recognition_enabled INTEGER NOT NULL DEFAULT 1 CHECK(recognition_enabled IN (0,1)),
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0)
);
CREATE TABLE voice_samples (
  id TEXT PRIMARY KEY NOT NULL,
  known_speaker_id TEXT NOT NULL REFERENCES known_speakers(id) ON DELETE CASCADE,
  engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
  model_manifest_hash TEXT NOT NULL CHECK(length(model_manifest_hash)=64 AND model_manifest_hash NOT GLOB '*[^0-9a-f]*'),
  dimension INTEGER NOT NULL CHECK(dimension BETWEEN 1 AND 4096),
  pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB)) BETWEEN 1 AND 256),
  vector BLOB NOT NULL CHECK(length(vector) = dimension * 4),
  quality_label TEXT NOT NULL CHECK(quality_label IN ('good','fair')),
  quality_score REAL NOT NULL CHECK(quality_score BETWEEN 0 AND 1),
  engine_quality REAL,
  speech_ms INTEGER NOT NULL CHECK(speech_ms>0),
  track TEXT NOT NULL CHECK(track IN ('microphone','system')),
  start_ms INTEGER NOT NULL CHECK(start_ms>=0),
  end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
  source_meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
  source_speaker_id TEXT REFERENCES meeting_speakers(id) ON DELETE SET NULL,
  consent TEXT NOT NULL CHECK(consent IN ('remember','also_remember','local_enroll')),
  active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
  created_at INTEGER NOT NULL,
  retired_at INTEGER,
  CHECK((retired_at IS NOT NULL) = (active = 0))
);
CREATE TABLE identification_runs (
  id TEXT PRIMARY KEY NOT NULL,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  diarization_run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
  state TEXT NOT NULL CHECK(state IN ('pending','running','succeeded','failed','interrupted','superseded')),
  "trigger" TEXT NOT NULL CHECK("trigger" IN ('automatic','manual','retry','past_search','sample_change')),
  engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
  model_manifest_hash TEXT NOT NULL CHECK(length(model_manifest_hash)=64 AND model_manifest_hash NOT GLOB '*[^0-9a-f]*'),
  dimension INTEGER NOT NULL CHECK(dimension BETWEEN 1 AND 4096),
  pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB)) BETWEEN 1 AND 256),
  threshold_policy TEXT NOT NULL CHECK(length(CAST(threshold_policy AS BLOB)) BETWEEN 1 AND 128),
  created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
  failure_category TEXT CHECK(failure_category IS NULL OR failure_category IN ('model_unavailable','os_unsupported','model_load_failure','audio_missing','audio_decode_failure','runtime_failure','diarization_changed','persistence_failure','persistence_capacity','interrupted')),
  failure_detail TEXT CHECK(failure_detail IS NULL OR length(CAST(failure_detail AS BLOB))<=512),
  cluster_count INTEGER NOT NULL DEFAULT 0 CHECK(cluster_count>=0),
  candidate_count INTEGER NOT NULL DEFAULT 0 CHECK(candidate_count>=0),
  region_count INTEGER NOT NULL DEFAULT 0 CHECK(region_count>=0),
  rejected_region_count INTEGER NOT NULL DEFAULT 0 CHECK(rejected_region_count>=0),
  comparison_count INTEGER NOT NULL DEFAULT 0 CHECK(comparison_count>=0),
  recognized_count INTEGER NOT NULL DEFAULT 0 CHECK(recognized_count>=0),
  suggested_count INTEGER NOT NULL DEFAULT 0 CHECK(suggested_count>=0),
  unknown_count INTEGER NOT NULL DEFAULT 0 CHECK(unknown_count>=0),
  preserved_manual_count INTEGER NOT NULL DEFAULT 0 CHECK(preserved_manual_count>=0),
  preemption_count INTEGER NOT NULL DEFAULT 0 CHECK(preemption_count>=0), inference_path TEXT NOT NULL DEFAULT 'local'
  CHECK (inference_path IN ('local','server','local_after_server_failure')), server_failure TEXT
  CHECK (server_failure IS NULL OR (inference_path != 'server' AND server_failure IN ('unreachable','busy','worker_unavailable','not_offered','user_ran_locally'))),
  CHECK((failure_category IS NOT NULL) = (state IN ('failed','interrupted')))
);
CREATE TABLE meeting_identification (
  meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  accepted_run_id TEXT REFERENCES identification_runs(id) ON DELETE SET NULL,
  current_run_id TEXT REFERENCES identification_runs(id) ON DELETE SET NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE identity_assignments (
  id TEXT PRIMARY KEY NOT NULL,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  meeting_speaker_id TEXT NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
  scope TEXT NOT NULL CHECK(scope IN ('self','merged')),
  known_speaker_id TEXT REFERENCES known_speakers(id) ON DELETE CASCADE,
  state TEXT NOT NULL CHECK(state IN ('recognized','possible','confirmed','rejected_unknown','unknown')),
  origin TEXT NOT NULL CHECK(origin IN ('automatic_match','user_confirmation','manual_profile_selection','new_profile_created','manual_correction','kept_unknown')),
  run_id TEXT REFERENCES identification_runs(id) ON DELETE SET NULL,
  score REAL CHECK(score IS NULL OR score BETWEEN -1 AND 1),
  engine TEXT, model_id TEXT, model_revision TEXT, threshold_policy TEXT,
  second_known_speaker_id TEXT REFERENCES known_speakers(id) ON DELETE SET NULL,
  confirmed_at INTEGER, corrected_at INTEGER,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  UNIQUE(meeting_speaker_id, scope),
  CHECK((state IN ('recognized','possible','confirmed')) = (known_speaker_id IS NOT NULL)),
  CHECK(state NOT IN ('recognized','possible') OR origin = 'automatic_match'),
  CHECK(state <> 'confirmed' OR origin IN ('user_confirmation','manual_profile_selection','new_profile_created','manual_correction')),
  CHECK(state <> 'rejected_unknown' OR origin = 'kept_unknown'),
  CHECK((confirmed_at IS NOT NULL) = (state = 'confirmed')),
  CHECK(state NOT IN ('recognized','possible') OR (score IS NOT NULL AND run_id IS NOT NULL)),
  CHECK(score IS NULL OR (engine IS NOT NULL AND model_id IS NOT NULL AND model_revision IS NOT NULL AND threshold_policy IS NOT NULL))
);
CREATE TABLE match_candidates (
  run_id TEXT NOT NULL REFERENCES identification_runs(id) ON DELETE CASCADE,
  meeting_speaker_id TEXT NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
  known_speaker_id TEXT NOT NULL REFERENCES known_speakers(id) ON DELETE CASCADE,
  score REAL NOT NULL CHECK(score BETWEEN -1 AND 1),
  tier TEXT NOT NULL CHECK(tier IN ('recognized','possible','below','local_evidence')),
  reasons TEXT NOT NULL DEFAULT '' CHECK(length(CAST(reasons AS BLOB))<=128),
  sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count>=0),
  support_count INTEGER NOT NULL DEFAULT 0 CHECK(support_count>=0),
  PRIMARY KEY(run_id, meeting_speaker_id, known_speaker_id)
) WITHOUT ROWID;
CREATE TABLE rejected_candidates (
  meeting_speaker_id TEXT NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
  known_speaker_id TEXT NOT NULL REFERENCES known_speakers(id) ON DELETE CASCADE,
  rejected_at INTEGER NOT NULL,
  PRIMARY KEY(meeting_speaker_id, known_speaker_id)
) WITHOUT ROWID;
CREATE TABLE analysis_runs (
  id TEXT PRIMARY KEY NOT NULL,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  state TEXT NOT NULL CHECK(state IN ('pending','running','succeeded','failed','cancelled','timed_out','interrupted','superseded')),
  "trigger" TEXT NOT NULL CHECK("trigger" IN ('automatic','manual','retry','regenerate','restart')),
  evidence_version TEXT NOT NULL CHECK(length(evidence_version)=64 AND evidence_version NOT GLOB '*[^0-9a-f]*'),
  transcript_pass_id TEXT,
  server_version TEXT CHECK(server_version IS NULL OR length(CAST(server_version AS BLOB))<=64),
  protocol_version INTEGER NOT NULL CHECK(protocol_version=1),
  schema_version INTEGER NOT NULL CHECK(schema_version=1),
  backend_kind TEXT CHECK(backend_kind IS NULL OR length(CAST(backend_kind AS BLOB))<=128),
  backend_model TEXT CHECK(backend_model IS NULL OR length(CAST(backend_model AS BLOB))<=128),
  prompt_versions TEXT CHECK(prompt_versions IS NULL OR length(CAST(prompt_versions AS BLOB))<=128),
  pipeline_version TEXT CHECK(pipeline_version IS NULL OR length(CAST(pipeline_version AS BLOB))<=64),
  language_policy TEXT CHECK(language_policy IS NULL OR language_policy IN ('sk','en','mixed')),
  request_config_json TEXT CHECK(request_config_json IS NULL OR length(CAST(request_config_json AS BLOB))<=2048),
  created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
  failure_category TEXT CHECK(failure_category IS NULL OR failure_category IN ('not_eligible','server_unreachable','authentication_failed','server_unavailable','backend_unavailable','backend_busy','backend_timeout','unsupported_version','malformed_response','oversized_response','meeting_mismatch','source_validation','protected_literal','unsupported_content','over_cap','too_long','timeout','persistence_failure','persistence_capacity','interrupted')),
  failure_detail TEXT CHECK(failure_detail IS NULL OR length(CAST(failure_detail AS BLOB))<=512),
  chunk_count INTEGER NOT NULL DEFAULT 0 CHECK(chunk_count>=0), request_count INTEGER NOT NULL DEFAULT 0 CHECK(request_count>=0), retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count>=0), preemption_count INTEGER NOT NULL DEFAULT 0 CHECK(preemption_count>=0), input_bytes INTEGER NOT NULL DEFAULT 0 CHECK(input_bytes>=0), output_bytes INTEGER NOT NULL DEFAULT 0 CHECK(output_bytes>=0), item_count INTEGER NOT NULL DEFAULT 0 CHECK(item_count>=0), dropped_literal_count INTEGER NOT NULL DEFAULT 0 CHECK(dropped_literal_count>=0), dropped_unsupported_count INTEGER NOT NULL DEFAULT 0 CHECK(dropped_unsupported_count>=0), identity_downgrade_count INTEGER NOT NULL DEFAULT 0 CHECK(identity_downgrade_count>=0), unresolved_owner_count INTEGER NOT NULL DEFAULT 0 CHECK(unresolved_owner_count>=0), duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(duration_ms>=0), inference_path TEXT NOT NULL DEFAULT 'local'
  CHECK (inference_path IN ('local','server','local_after_server_failure','custom')), server_failure TEXT
  CHECK (server_failure IS NULL OR (inference_path != 'server' AND server_failure IN ('unreachable','busy','worker_unavailable','not_offered','user_ran_locally'))),
  CHECK((failure_category IS NOT NULL) = (state IN ('failed','timed_out','interrupted')))
);
CREATE TABLE meeting_analysis (
  meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  accepted_run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
  current_run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
  accepted_evidence_version TEXT CHECK(accepted_evidence_version IS NULL OR length(accepted_evidence_version)=64 AND accepted_evidence_version NOT GLOB '*[^0-9a-f]*'),
  auto_restarted_at INTEGER,
  updated_at INTEGER NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0)
);
CREATE TABLE analysis_summaries (
  run_id TEXT PRIMARY KEY NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 4000),
  language TEXT NOT NULL CHECK(language IN ('sk','en','mixed')),
  whole_meeting INTEGER NOT NULL CHECK(whole_meeting IN (0,1))
);
CREATE TABLE analysis_topics (
  id TEXT PRIMARY KEY NOT NULL,
  run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL CHECK(ordinal>=0),
  title TEXT NOT NULL CHECK(length(CAST(title AS BLOB)) BETWEEN 1 AND 200),
  summary TEXT NOT NULL CHECK(length(CAST(summary AS BLOB))<=2000),
  bullets_json TEXT NOT NULL CHECK(length(CAST(bullets_json AS BLOB))<=8192),
  UNIQUE(run_id, ordinal)
);
CREATE TABLE analysis_items (
  id TEXT PRIMARY KEY NOT NULL,
  run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('decision','action_item','next_step','open_question','risk')),
  ordinal INTEGER NOT NULL CHECK(ordinal>=0),
  text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 1000),
  evidence_class TEXT CHECK(evidence_class IS NULL OR evidence_class IN ('explicit','implied')),
  topic_id TEXT REFERENCES analysis_topics(id) ON DELETE SET NULL,
  owner_kind TEXT CHECK(owner_kind IS NULL OR owner_kind IN ('participant','mentioned','none')),
  owner_speaker_id TEXT REFERENCES meeting_speakers(id) ON DELETE SET NULL,
  owner_known_speaker_id TEXT REFERENCES known_speakers(id) ON DELETE SET NULL,
  owner_name TEXT CHECK(owner_name IS NULL OR length(CAST(owner_name AS BLOB)) BETWEEN 1 AND 80),
  owner_certainty TEXT CHECK(owner_certainty IS NULL OR owner_certainty IN ('confirmed','recognized','local_name','local_user')),
  ownership_state TEXT CHECK(ownership_state IS NULL OR ownership_state IN ('explicit','supported','unresolved')),
  due_state TEXT CHECK(due_state IS NULL OR due_state IN ('explicit_absolute','explicit_relative_resolved','unresolved','absent')),
  due_date TEXT CHECK(due_date IS NULL OR due_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  due_original TEXT CHECK(due_original IS NULL OR length(CAST(due_original AS BLOB))<=80),
  due_source_segment_id TEXT,
  due_source_note_ordinal INTEGER CHECK(due_source_note_ordinal IS NULL OR due_source_note_ordinal>=1),
  UNIQUE(run_id, kind, ordinal),
  CHECK(kind<>'action_item' OR (
    owner_kind IS NOT NULL AND ownership_state IS NOT NULL AND due_state IS NOT NULL)),
  CHECK(kind='action_item' OR (
    owner_kind IS NULL AND owner_speaker_id IS NULL AND owner_known_speaker_id IS NULL
    AND owner_name IS NULL AND owner_certainty IS NULL AND ownership_state IS NULL
    AND due_state IS NULL AND due_date IS NULL AND due_original IS NULL
    AND due_source_segment_id IS NULL AND due_source_note_ordinal IS NULL)),
  CHECK((owner_kind='participant') = (owner_speaker_id IS NOT NULL)),
  CHECK(owner_known_speaker_id IS NULL OR owner_kind='participant'),
  CHECK((owner_name IS NULL) = (owner_kind IS NULL OR owner_kind<>'mentioned')),
  CHECK((owner_certainty IS NULL) = (owner_kind IS NULL OR owner_kind<>'participant')),
  CHECK(owner_kind IS NULL OR owner_kind<>'mentioned' OR ownership_state IN ('supported','unresolved')),
  CHECK(owner_kind IS NULL OR owner_kind<>'none' OR ownership_state='unresolved'),
  CHECK((due_date IS NOT NULL) = (due_state IN ('explicit_absolute','explicit_relative_resolved'))),
  CHECK((due_original IS NULL) = (due_state IS NULL OR due_state='absent')),
  CHECK((due_state='absent') = (due_source_segment_id IS NULL AND due_source_note_ordinal IS NULL)),
  CHECK(due_source_segment_id IS NULL OR due_source_note_ordinal IS NULL)
);
CREATE TABLE analysis_sources (
  run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  target_kind TEXT NOT NULL CHECK(target_kind IN ('summary','topic','item')),
  target_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal>=0),
  source_kind TEXT NOT NULL CHECK(source_kind IN ('segment','note')),
  segment_id TEXT REFERENCES transcript_segments(id) ON DELETE CASCADE,
  note_ordinal INTEGER CHECK(note_ordinal IS NULL OR note_ordinal>=1),
  note_hash TEXT CHECK(note_hash IS NULL OR length(note_hash)=64 AND note_hash NOT GLOB '*[^0-9a-f]*'),
  PRIMARY KEY(target_kind, target_id, ordinal),
  CHECK((source_kind='segment') = (segment_id IS NOT NULL)),
  CHECK((source_kind='note') = (note_ordinal IS NOT NULL)),
  CHECK((note_hash IS NOT NULL) = (source_kind='note'))
) WITHOUT ROWID;
CREATE TABLE analysis_overlays (
  id TEXT PRIMARY KEY NOT NULL,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  item_id TEXT REFERENCES analysis_items(id) ON DELETE SET NULL,
  target_kind TEXT NOT NULL CHECK(target_kind IN ('summary','item')),
  item_kind TEXT CHECK(item_kind IS NULL OR item_kind IN ('decision','action_item','next_step','open_question','risk')),
  field TEXT NOT NULL CHECK(field IN ('summary_text','task_text','decision_text','next_step_text','owner','due_date','status')),
  user_value TEXT NOT NULL CHECK(length(CAST(user_value AS BLOB))<=4000),
  ai_value_snapshot TEXT CHECK(ai_value_snapshot IS NULL OR length(CAST(ai_value_snapshot AS BLOB))<=4000),
  item_text_snapshot TEXT CHECK(item_text_snapshot IS NULL OR length(CAST(item_text_snapshot AS BLOB))<=1000),
  source_key TEXT CHECK(source_key IS NULL OR length(CAST(source_key AS BLOB))<=1024),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  orphaned_at INTEGER,
  CHECK(target_kind='summary' OR item_kind IS NOT NULL),
  CHECK(target_kind='item' OR (item_kind IS NULL AND item_id IS NULL))
);
CREATE TABLE "rewrite_attempts" ("id" TEXT PRIMARY KEY NOT NULL, "transcription_id" TEXT NOT NULL REFERENCES "transcriptions"("id") ON DELETE CASCADE, "ordinal" INTEGER NOT NULL CHECK (ordinal BETWEEN 1 AND 10), "mode" TEXT NOT NULL CHECK (mode IN ('clean','polished','concise')), "state" TEXT NOT NULL CHECK (state IN ('pending','succeeded','failed','cancelled','timed_out')), "input_text" TEXT NOT NULL CHECK (length(cast(input_text AS blob)) BETWEEN 1 AND 65536), "input_hash" TEXT NOT NULL CHECK (length(input_hash) = 64), "output_text" TEXT CHECK (output_text IS NULL OR length(cast(output_text AS blob)) <= 65536), "output_hash" TEXT CHECK (output_hash IS NULL OR length(output_hash) = 64), "unchanged" INTEGER NOT NULL CHECK (unchanged IN (0,1)) DEFAULT 0, "failure_category" TEXT CHECK (failure_category IS NULL OR failure_category IN ('server_unreachable','timeout','authentication_failed','transport_error','backend_unavailable','malformed_response','unsupported_schema_version','empty_response','oversized_response','server_validation_failed','request_mismatch','interrupted','context_copied')), "stale" INTEGER NOT NULL CHECK (stale IN (0,1)) DEFAULT 0, "started_at" INTEGER NOT NULL CHECK (started_at >= 0), "duration_ms" INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0), "first_byte_ms" INTEGER CHECK (first_byte_ms IS NULL OR first_byte_ms >= 0), "network_ms" INTEGER CHECK (network_ms IS NULL OR network_ms >= 0), "server_queue_ms" INTEGER CHECK (server_queue_ms IS NULL OR server_queue_ms >= 0), "backend_first_token_ms" INTEGER CHECK (backend_first_token_ms IS NULL OR backend_first_token_ms >= 0), "backend_ms" INTEGER CHECK (backend_ms IS NULL OR backend_ms >= 0), "request_bytes" INTEGER CHECK (request_bytes IS NULL OR request_bytes >= 0), "response_bytes" INTEGER CHECK (response_bytes IS NULL OR response_bytes >= 0), "protocol_version" INTEGER NOT NULL CHECK (protocol_version IN (1,2)), "server_name" TEXT CHECK (server_name IS NULL OR length(cast(server_name AS blob)) BETWEEN 1 AND 128), "server_version" TEXT CHECK (server_version IS NULL OR length(cast(server_version AS blob)) BETWEEN 1 AND 128), "backend_kind" TEXT CHECK (backend_kind IS NULL OR length(cast(backend_kind AS blob)) BETWEEN 1 AND 128), "backend_model" TEXT CHECK (backend_model IS NULL OR length(cast(backend_model AS blob)) BETWEEN 1 AND 128), "prompt_version" INTEGER CHECK (prompt_version IS NULL OR prompt_version >= 0), "shield_version" INTEGER CHECK (shield_version IS NULL OR shield_version >= 0), "endpoint_origin" TEXT NOT NULL CHECK (length(cast(endpoint_origin AS blob)) BETWEEN 1 AND 255), "insecure_override" INTEGER NOT NULL CHECK (insecure_override IN (0,1)) DEFAULT 0, "delivered" INTEGER NOT NULL CHECK (delivered IN (0,1)) DEFAULT 0, "context_hash" TEXT CHECK (context_hash IS NULL OR (length(context_hash) = 64 AND context_hash NOT GLOB '*[^0-9a-f]*')), CHECK ((state = 'succeeded') = (output_text IS NOT NULL)), CHECK ((output_text IS NULL) = (output_hash IS NULL)), CHECK ((state IN ('failed','timed_out')) = (failure_category IS NOT NULL)), CHECK (state != 'timed_out' OR failure_category = 'timeout'), CHECK ((protocol_version = 2) = (context_hash IS NOT NULL)));
CREATE TABLE term_suggestions (
  canonical TEXT NOT NULL CHECK(length(cast(canonical AS blob)) BETWEEN 1 AND 256),
  alias TEXT NOT NULL CHECK(length(cast(alias AS blob)) <= 256),
  sightings INTEGER NOT NULL CHECK(sightings >= 0),
  dismissed INTEGER NOT NULL CHECK(dismissed IN (0,1)),
  last_seen INTEGER NOT NULL,
  PRIMARY KEY(canonical, alias)
) WITHOUT ROWID;
CREATE TABLE pending_remote_dictations (
  id TEXT PRIMARY KEY,
  audio_file TEXT NOT NULL,
  sample_count INTEGER NOT NULL CHECK (sample_count BETWEEN 1 AND 2880000),
  created_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  last_failure TEXT,
  target_bundle_id TEXT
, input_device_name TEXT
  CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128), input_device_kind TEXT
  CHECK (input_device_kind IS NULL OR input_device_kind IN
    ('builtIn','usb','bluetooth','iPhone','virtual','other','systemDefault')), usage_attribution TEXT CHECK(length(usage_attribution)<=2048));
CREATE TABLE dictionary_key_usage (
  entry_id TEXT NOT NULL REFERENCES vocabulary_entries(id) ON DELETE CASCADE,
  key_id TEXT NOT NULL CHECK(length(key_id) BETWEEN 1 AND 32),
  state TEXT NOT NULL CHECK(state IN ('provisional','established','retired')),
  applied INTEGER NOT NULL DEFAULT 0 CHECK(applied >= 0),
  kept INTEGER NOT NULL DEFAULT 0 CHECK(kept >= 0),
  reverted INTEGER NOT NULL DEFAULT 0 CHECK(reverted >= 0),
  last_used_at INTEGER,
  retired_at INTEGER,
  retired_from TEXT CHECK(retired_from IS NULL OR retired_from IN ('provisional','established')),
  notice_shown INTEGER NOT NULL DEFAULT 0 CHECK(notice_shown IN (0,1)),
  PRIMARY KEY(entry_id, key_id),
  CHECK((state = 'retired') = (retired_at IS NOT NULL))
) WITHOUT ROWID;
CREATE TABLE dictionary_usage_events (
  id INTEGER PRIMARY KEY,
  dictation_id TEXT NOT NULL,
  entry_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK(outcome IN ('applied','kept','reverted','unclassified')),
  at INTEGER NOT NULL,
  UNIQUE(dictation_id, entry_id, key_id)
);
CREATE TABLE dictionary_usage_state (
  id INTEGER PRIMARY KEY CHECK(id = 1),
  revision INTEGER NOT NULL CHECK(revision >= 0)
);
CREATE TABLE correction_sightings (
  digest BLOB PRIMARY KEY CHECK(length(digest) = 32),
  count INTEGER NOT NULL CHECK(count BETWEEN 1 AND 3),
  last_seen INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TABLE "transcript_live_gaps" (
  id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  pass_id TEXT NOT NULL, stretch_sequence INTEGER NOT NULL CHECK(stretch_sequence>=1),
  start_ms INTEGER NOT NULL CHECK(start_ms>=0), end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
  reason TEXT NOT NULL CHECK(reason IN ('backpressure','suspended','tap_overflow','pause_drain','stop_drain','model_reload','server_unavailable')),
  covered_by_final INTEGER NOT NULL DEFAULT 0 CHECK(covered_by_final IN (0,1)), created_at INTEGER NOT NULL
);
CREATE TABLE "meeting_segments" (
  id TEXT NOT NULL PRIMARY KEY,
  track_id TEXT NOT NULL REFERENCES meeting_tracks(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL CHECK (sequence >= 1),
  relative_path TEXT NOT NULL
    CHECK (length(cast(relative_path AS blob)) BETWEEN 1 AND 255),
  state TEXT NOT NULL CHECK (state IN ('open','finalized','unrecoverable')),
  start_offset_ms INTEGER NOT NULL CHECK (start_offset_ms >= 0),
  duration_ms INTEGER NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
  byte_size INTEGER NOT NULL DEFAULT 0 CHECK (byte_size >= 0),
  started_at INTEGER NOT NULL,
  host_start_ns INTEGER NOT NULL CHECK (host_start_ns >= 0),
  open_reason TEXT NOT NULL
    CHECK (open_reason IN ('start','resume','device_changed','rotated')),
  close_reason TEXT CHECK (close_reason IS NULL OR close_reason IN
    ('pause','system_sleep','stop','source_failed','storage_failed','device_changed','recovered','rotated')),
  dropped_frames INTEGER NOT NULL DEFAULT 0 CHECK (dropped_frames >= 0),
  recovery_note TEXT
    CHECK (recovery_note IS NULL OR length(cast(recovery_note AS blob)) <= 512),
  failure_reason TEXT CHECK (failure_reason IS NULL OR failure_reason IN ('not_running_at_last_state','storage_write_failed','storage_unavailable','encoder_failed','permission_revoked','device_lost','stream_stopped','both_sources_failed','record_missing','file_missing','segment_open_failed','unrecoverable_media')),
  input_device_name TEXT
    CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128),
  CHECK ((failure_reason IS NOT NULL) = (state = 'unrecoverable'))
);
CREATE TABLE "dictation_contexts" (
  transcription_id TEXT NOT NULL PRIMARY KEY
    REFERENCES transcriptions(id) ON DELETE CASCADE,
  outcome TEXT NOT NULL CHECK(outcome IN ('used','off','excluded_app','own_app','secure_field','no_permission','nothing_readable','timed_out','no_target','changed_field')),
  capture_ms INTEGER CHECK(capture_ms IS NULL OR capture_ms >= 0),
  app_bundle_id TEXT CHECK(app_bundle_id IS NULL
    OR length(cast(app_bundle_id AS blob)) BETWEEN 1 AND 255),
  snapshot_json TEXT CHECK(snapshot_json IS NULL
    OR length(cast(snapshot_json AS blob)) <= 8192),
  snapshot_hash TEXT CHECK(snapshot_hash IS NULL OR (length(snapshot_hash) = 64 AND snapshot_hash NOT GLOB '*[^0-9a-f]*')),
  pre_spelling_text TEXT CHECK(pre_spelling_text IS NULL
    OR length(cast(pre_spelling_text AS blob)) <= 65536),
  spelling_changes_json TEXT CHECK(spelling_changes_json IS NULL
    OR length(cast(spelling_changes_json AS blob)) <= 32768),
  speller_version INTEGER CHECK(speller_version IS NULL OR speller_version >= 1),
  rewrite_note TEXT CHECK(rewrite_note IS NULL OR rewrite_note = 'server_unsupported'),
  CHECK((snapshot_json IS NULL) = (snapshot_hash IS NULL)),
  CHECK((pre_spelling_text IS NULL) = (spelling_changes_json IS NULL)),
  CHECK(outcome NOT IN ('used','timed_out') OR snapshot_json IS NOT NULL),
  CHECK(outcome != 'off' OR (snapshot_json IS NULL AND app_bundle_id IS NULL
    AND capture_ms IS NULL AND pre_spelling_text IS NULL))
);
CREATE TABLE usage_reporting_state (
  id INTEGER PRIMARY KEY CHECK(id=1), binding TEXT CHECK(length(binding)<=2048),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  pending TEXT CHECK(pending IN ('withdraw','delete_device','delete_user')),
  incomplete INTEGER NOT NULL DEFAULT 0 CHECK(incomplete IN (0,1)), last_report INTEGER
);
CREATE TABLE usage_reporting_days (
  day TEXT PRIMARY KEY CHECK(length(day)=10), revision INTEGER NOT NULL CHECK(revision>0),
  local_count INTEGER NOT NULL CHECK(local_count>=0), remote_count INTEGER NOT NULL CHECK(remote_count>=0),
  local_audio_ms INTEGER NOT NULL CHECK(local_audio_ms>=0), remote_audio_ms INTEGER NOT NULL CHECK(remote_audio_ms>=0),
  coverage TEXT NOT NULL CHECK(coverage IN ('complete','partial')), dirty INTEGER NOT NULL CHECK(dirty IN (0,1))
);
CREATE TABLE usage_reporting_completions (
  id TEXT PRIMARY KEY CHECK(length(id)=36), day TEXT NOT NULL CHECK(length(day)=10)
);
CREATE INDEX transcriptions_created_at_id ON transcriptions(created_at DESC, id DESC);
CREATE INDEX meetings_created_at_id ON meetings(created_at DESC, id DESC);
CREATE INDEX meetings_active ON meetings(state) WHERE state IN ('created','preparing','recording','paused','finalizing');
CREATE UNIQUE INDEX meeting_tracks_meeting_type ON meeting_tracks(meeting_id, type);
CREATE UNIQUE INDEX meeting_pauses_open ON meeting_pauses(meeting_id) WHERE ended_at IS NULL;
CREATE INDEX meeting_recovery_outcomes_meeting ON meeting_recovery_outcomes(meeting_id);
CREATE INDEX meeting_transcriptions_active ON meeting_transcriptions(state) WHERE state IN ('pending','live','finalizing');
CREATE INDEX transcript_segments_page ON transcript_segments(meeting_id,finality,ordinal);
CREATE INDEX transcript_segments_pass ON transcript_segments(pass_id);
CREATE INDEX diarization_runs_meeting ON diarization_runs(meeting_id, created_at);
CREATE UNIQUE INDEX diarization_runs_active ON diarization_runs(meeting_id)
  WHERE state IN ('pending','running');
CREATE UNIQUE INDEX meeting_speakers_cluster ON meeting_speakers(run_id, cluster_key)
  WHERE run_id IS NOT NULL;
CREATE INDEX meeting_speakers_meeting ON meeting_speakers(meeting_id);
CREATE INDEX speaker_turns_run_start ON speaker_turns(run_id, start_ms);
CREATE INDEX speaker_turns_speaker ON speaker_turns(speaker_id);
CREATE INDEX speaker_assignments_segment ON speaker_assignments(segment_id);
CREATE INDEX speaker_corrections_meeting ON speaker_corrections(meeting_id, created_at);
CREATE UNIQUE INDEX known_speakers_local_user ON known_speakers(is_local_user)
  WHERE is_local_user = 1;
CREATE INDEX voice_samples_speaker_active ON voice_samples(known_speaker_id, active);
CREATE INDEX voice_samples_source_meeting ON voice_samples(source_meeting_id);
CREATE INDEX voice_samples_source_speaker ON voice_samples(source_speaker_id);
CREATE INDEX identification_runs_meeting ON identification_runs(meeting_id, created_at);
CREATE UNIQUE INDEX identification_runs_active ON identification_runs(meeting_id)
  WHERE state IN ('pending','running');
CREATE INDEX identity_assignments_known ON identity_assignments(known_speaker_id);
CREATE INDEX identity_assignments_meeting ON identity_assignments(meeting_id);
CREATE INDEX match_candidates_known ON match_candidates(known_speaker_id);
CREATE INDEX match_candidates_speaker ON match_candidates(meeting_speaker_id);
CREATE INDEX rejected_candidates_known ON rejected_candidates(known_speaker_id);
CREATE INDEX analysis_runs_meeting ON analysis_runs(meeting_id, created_at);
CREATE UNIQUE INDEX analysis_runs_active ON analysis_runs(meeting_id)
  WHERE state IN ('pending','running');
CREATE INDEX analysis_sources_run ON analysis_sources(run_id);
CREATE UNIQUE INDEX analysis_overlays_item_field ON analysis_overlays(item_id, field)
  WHERE item_id IS NOT NULL;
CREATE UNIQUE INDEX analysis_overlays_summary ON analysis_overlays(meeting_id)
  WHERE target_kind='summary';
CREATE INDEX analysis_overlays_meeting ON analysis_overlays(meeting_id);
CREATE UNIQUE INDEX rewrite_attempts_transcription_ordinal
  ON rewrite_attempts(transcription_id, ordinal);
CREATE INDEX rewrite_attempts_state ON rewrite_attempts(state) WHERE state = 'pending';
CREATE INDEX analysis_items_fk_meeting_id ON analysis_items(meeting_id);
CREATE INDEX analysis_items_fk_owner_known_speaker_id ON analysis_items(owner_known_speaker_id);
CREATE INDEX analysis_items_fk_owner_speaker_id ON analysis_items(owner_speaker_id);
CREATE INDEX analysis_items_fk_topic_id ON analysis_items(topic_id);
CREATE INDEX analysis_overlays_fk_item_id ON analysis_overlays(item_id);
CREATE INDEX analysis_sources_fk_meeting_id ON analysis_sources(meeting_id);
CREATE INDEX analysis_sources_fk_segment_id ON analysis_sources(segment_id);
CREATE INDEX analysis_summaries_fk_meeting_id ON analysis_summaries(meeting_id);
CREATE INDEX analysis_topics_fk_meeting_id ON analysis_topics(meeting_id);
CREATE INDEX identification_runs_fk_diarization_run_id ON identification_runs(diarization_run_id);
CREATE INDEX identity_assignments_fk_run_id ON identity_assignments(run_id);
CREATE INDEX identity_assignments_fk_second_known_speaker_id ON identity_assignments(second_known_speaker_id);
CREATE INDEX meeting_analysis_fk_accepted_run_id ON meeting_analysis(accepted_run_id);
CREATE INDEX meeting_analysis_fk_current_run_id ON meeting_analysis(current_run_id);
CREATE INDEX meeting_diarization_fk_accepted_run_id ON meeting_diarization(accepted_run_id);
CREATE INDEX meeting_diarization_fk_current_run_id ON meeting_diarization(current_run_id);
CREATE INDEX meeting_identification_fk_accepted_run_id ON meeting_identification(accepted_run_id);
CREATE INDEX meeting_identification_fk_current_run_id ON meeting_identification(current_run_id);
CREATE INDEX meeting_pauses_fk_meeting_id ON meeting_pauses(meeting_id);
CREATE INDEX meeting_speakers_fk_merged_into ON meeting_speakers(merged_into);
CREATE INDEX meeting_speakers_fk_run_id ON meeting_speakers(run_id);
CREATE INDEX speaker_assignments_fk_auto_speaker_id ON speaker_assignments(auto_speaker_id);
CREATE INDEX speaker_assignments_fk_manual_speaker_id ON speaker_assignments(manual_speaker_id);
CREATE INDEX speaker_corrections_fk_run_id ON speaker_corrections(run_id);
CREATE INDEX transcriptions_fk_delivered_rewrite_attempt_id ON transcriptions(delivered_rewrite_attempt_id);
CREATE INDEX dictionary_key_usage_last_used ON dictionary_key_usage(last_used_at);
CREATE INDEX dictionary_usage_events_entry ON dictionary_usage_events(entry_id);
CREATE INDEX transcript_live_gaps_fk_meeting_id ON transcript_live_gaps(meeting_id);
CREATE UNIQUE INDEX meeting_segments_track_sequence ON meeting_segments(track_id, sequence);
CREATE INDEX usage_reporting_completion_day ON usage_reporting_completions(day);
INSERT INTO "grdb_migrations" VALUES ('history-v1');
INSERT INTO "grdb_migrations" VALUES ('quality-v2');
INSERT INTO "grdb_migrations" VALUES ('vocabulary-v3');
INSERT INTO "grdb_migrations" VALUES ('rewrite-v4');
INSERT INTO "grdb_migrations" VALUES ('meetings-v5');
INSERT INTO "grdb_migrations" VALUES ('transcripts-v6');
INSERT INTO "grdb_migrations" VALUES ('speakers-v7');
INSERT INTO "grdb_migrations" VALUES ('identities-v8');
INSERT INTO "grdb_migrations" VALUES ('intelligence-v9');
INSERT INTO "grdb_migrations" VALUES ('meeting-language-v10');
INSERT INTO "grdb_migrations" VALUES ('app-context-v11');
INSERT INTO "grdb_migrations" VALUES ('meeting-language-en-sk-v12');
INSERT INTO "grdb_migrations" VALUES ('foreign-key-indexes-v13');
INSERT INTO "grdb_migrations" VALUES ('term-suggestions-v14');
INSERT INTO "grdb_migrations" VALUES ('remote-dictation-v15');
INSERT INTO "grdb_migrations" VALUES ('dictionary-usage-v16');
INSERT INTO "grdb_migrations" VALUES ('one-server-v17');
INSERT INTO "grdb_migrations" VALUES ('input-device-v18');
INSERT INTO "grdb_migrations" VALUES ('phone-meetings-v19');
INSERT INTO "grdb_migrations" VALUES ('context-consistency-v20');
INSERT INTO "grdb_migrations" VALUES ('usage-reporting-v21');
INSERT INTO "history_usage" VALUES (1, 0, 0);
INSERT INTO "vocabulary_state" VALUES (1, 1, 0, 'f19d570a9cda5f4e010dea8023a43e09496762f177b342bdada82044d970ad22', 0);
INSERT INTO "transcript_usage" VALUES (1, 0, 0, 1);
INSERT INTO "dictionary_usage_state" VALUES (1, 0);
INSERT INTO "usage_reporting_state" VALUES (1, NULL, 0, NULL, 0, NULL);
