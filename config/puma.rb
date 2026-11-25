# A live search holds a thread for up to 64 s while it waits on the renderer,
# and the gate admits one every 10-15 s. Enough threads keep the page, the saved
# example and the health check answering while several searches are in flight;
# waiting threads cost little memory.
threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", "8"))
threads threads_count, threads_count
port ENV.fetch("PORT", "3000")
plugin :tmp_restart
