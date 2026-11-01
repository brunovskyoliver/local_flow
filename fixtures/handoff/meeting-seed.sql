-- One finished meeting and an unrelated one. {ID} and {OTHER} are replaced by the test. Used by
-- crates/flow-core/src/remote/handoff/tests.rs and packages/LocalFlowCore HandoffBundleCrossCheckTests.
INSERT INTO meetings(id,state,title,created_at,started_at,stopped_at,completed_at,wall_clock_ms,recorded_ms,finalization_stage,updated_at,revision) VALUES('{ID}','completed','Handoff fixture',1000,1000,61000,61000,60000,58000,'both',61000,3);
INSERT INTO meeting_tracks(id,meeting_id,type,codec,container,sample_rate,channel_count,bitrate,health,total_duration_ms,total_bytes) VALUES('{ID}-mic','{ID}','microphone','aac_lc','adts',48000,1,64000,'finalized',58000,100000),('{ID}-sys','{ID}','system','aac_lc','adts',48000,2,128000,'finalized',58000,100001);
INSERT INTO meeting_segments(id,track_id,sequence,relative_path,state,start_offset_ms,duration_ms,byte_size,started_at,host_start_ns,open_reason,close_reason) VALUES('{ID}-s1','{ID}-mic',1,'{ID}/mic-0001.aac','finalized',0,58000,100000,1000,0,'start','stop'),('{ID}-s2','{ID}-sys',1,'{ID}/system-0001.aac','finalized',0,58000,100001,1000,0,'start','stop');
INSERT INTO meeting_segments(id,track_id,sequence,relative_path,state,start_offset_ms,started_at,host_start_ns,open_reason,failure_reason) VALUES('{ID}-s3','{ID}-sys',2,'{ID}/system-0002.aac','unrecoverable',58000,59000,0,'resume','file_missing');
INSERT INTO meeting_pauses(id,meeting_id,started_at,ended_at,reason,closed_by) VALUES('{ID}-p','{ID}',2000,4000,'user','resume');
INSERT INTO meeting_notes(meeting_id,text,author,updated_at) VALUES('{ID}','Ask about the budget','user',5000);
INSERT INTO meeting_transcriptions(meeting_id,state,live_requested,segment_count,text_bytes,updated_at) VALUES('{ID}','pending',0,1,5,6000);
INSERT INTO transcript_segments(id,meeting_id,pass_id,finality,ordinal,stretch_sequence,start_ms,end_ms,window_index,timing_basis,raw_text,assembled_text,normalized_text,engine,model_id,model_revision,pipeline_version,analysis_tracks,created_at) VALUES('{ID}-live','{ID}','live','provisional',0,1,0,1000,0,'window','hello','hello','hello','e','m','r','p','mic',6000);
INSERT INTO transcript_live_gaps(id,meeting_id,pass_id,stretch_sequence,start_ms,end_ms,reason,created_at) VALUES('{ID}-gap','{ID}','live',1,1000,2000,'server_unavailable',6000);
INSERT INTO vocabulary_entries(id,canonical_text,aliases_json,enabled) VALUES('word-1','Homarr','[]',1);
INSERT INTO meetings(id,state,created_at,updated_at) VALUES('{OTHER}','completed',500,500);
INSERT INTO meeting_notes(meeting_id,text,author,updated_at) VALUES('{OTHER}','Not for the bundle','user',500);
INSERT INTO meeting_transcriptions(meeting_id,state,live_requested,segment_count,text_bytes,updated_at) VALUES('{OTHER}','final',0,7,70,500);
UPDATE transcript_usage SET text_bytes=75, segment_rows=8 WHERE id=1;
