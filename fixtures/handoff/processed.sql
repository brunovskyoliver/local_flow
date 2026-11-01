-- What a processor leaves in a bundle: final transcript, accepted labels and a summary for {ID}.
DELETE FROM transcript_segments WHERE meeting_id='{ID}';
UPDATE transcript_live_gaps SET covered_by_final=1 WHERE meeting_id='{ID}';
UPDATE meeting_transcriptions SET state='final',pass_id='final-1',pass_kind='final',engine='e',model_id='m',model_revision='r',finalized_at=70000,covered_ms=58000,segment_count=2,text_bytes=23,updated_at=70000,revision=revision+1 WHERE meeting_id='{ID}';
INSERT INTO transcript_segments(id,meeting_id,pass_id,finality,ordinal,stretch_sequence,start_ms,end_ms,window_index,timing_basis,raw_text,assembled_text,normalized_text,engine,model_id,model_revision,pipeline_version,analysis_tracks,created_at) VALUES('{ID}-f1','{ID}','final-1','final',0,1,0,30000,0,'word','Hello there','Hello there','Hello there','e','m','r','p','both',70000),('{ID}-f2','{ID}','final-1','final',1,1,30000,58000,1,'word','General Kenobi!','General Kenobi!','General Kenobi!','e','m','r','p','both',70000);
INSERT INTO diarization_runs(id,meeting_id,transcript_pass_id,state,"trigger",in_room,engine,model_id,model_revision,model_manifest_hash,pipeline_version,created_at,completed_at,turn_count) VALUES('{ID}-run','{ID}','final-1','succeeded','automatic',0,'e','m','r','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','p',70000,71000,2);
INSERT INTO meeting_speakers(id,meeting_id,run_id,cluster_key,source,track,origin) VALUES('{ID}-sp','{ID}','{ID}-run',0,'local','microphone','engine');
INSERT INTO speaker_turns(id,run_id,speaker_id,track,start_ms,end_ms) VALUES(901,'{ID}-run','{ID}-sp','microphone',0,30000),(902,'{ID}-run','{ID}-sp','microphone',30000,58000);
INSERT INTO speaker_assignments(run_id,segment_id,auto_kind,auto_speaker_id,top_coverage) VALUES('{ID}-run','{ID}-f1','speaker','{ID}-sp',1);
INSERT INTO meeting_diarization(meeting_id,accepted_run_id,updated_at) VALUES('{ID}','{ID}-run',71000);
INSERT INTO analysis_runs(id,meeting_id,state,"trigger",evidence_version,protocol_version,schema_version,created_at,completed_at) VALUES('{ID}-an','{ID}','succeeded','automatic','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',1,1,72000,73000);
INSERT INTO analysis_summaries(run_id,meeting_id,text,language,whole_meeting) VALUES('{ID}-an','{ID}','They greeted each other.','en',1);
INSERT INTO meeting_analysis(meeting_id,accepted_run_id,updated_at) VALUES('{ID}','{ID}-an',73000);
