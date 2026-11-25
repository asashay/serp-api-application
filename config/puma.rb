# A live search holds a thread for up to 114 s while it waits on the renderer,
# and the gate admits one every 10-15 s, so about ten can be in flight. Enough threads keep the page, the saved
# example and the health check answering while several searches are in flight;
# waiting threads cost little memory.
threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", "16"))
threads threads_count, threads_count
port ENV.fetch("PORT", "3000")
plugin :tmp_restart
