;;; Pseudo-terminal handling: spawning the shell, I/O and window size.
(library (chezterm pty)
  (export pty-spawn pty-resize! pty-read pty-write pty-child-exited? pty-hangup!
          default-shell spawn-detached process-cwd)
  (import (chezscheme) (chezterm ffi) (chezterm cutil))

  (define (default-shell)
    (or (getenv "SHELL")
        (let ([p (c-getenv "SHELL")]) (and (not (ptr-null? p)) (cstring->string p)))
        "/bin/sh"))

  (define (make-winsize rows cols xpixel ypixel)
    (let ([ws (malloc (ftype-sizeof winsize))])
      (let ([p (make-ftype-pointer winsize ws)])
        (ftype-set! winsize (ws_row) p rows)
        (ftype-set! winsize (ws_col) p cols)
        (ftype-set! winsize (ws_xpixel) p xpixel)
        (ftype-set! winsize (ws_ypixel) p ypixel))
      ws))

  ;; Build a NULL-terminated char*[] in C memory.
  (define (make-argv strs)
    (let ([argv (malloc (* 8 (+ 1 (length strs))))])
      (let loop ([ss strs] [i 0])
        (if (null? ss)
            (foreign-set! 'uptr argv (* 8 i) 0)
            (begin
              (foreign-set! 'uptr argv (* 8 i) (string->cstring (car ss)))
              (loop (cdr ss) (+ i 1)))))
      argv))

  ;; Start PROGRAM (a list: path and arguments) on a new pty of the given
  ;; size.  ENV is an alist of variables to set.  Returns (values fd pid).
  (define (pty-spawn program rows cols xpixel ypixel cwd env)
    (for-each (lambda (kv) (setenv (car kv) (cdr kv) 1)) env)
    (let* ([argv (make-argv program)]
           [file (foreign-ref 'uptr argv 0)]
           [cwd-c (if cwd (string->cstring cwd) 0)]
           [ws (make-winsize rows cols xpixel ypixel)]
           [master (malloc 8)]
           [sigset (malloc 128)])
      (sigemptyset sigset)
      (let ([pid (forkpty master 0 0 ws)])
        (cond
          [(< pid 0) (errorf 'pty-spawn "forkpty failed: ~a" (errno-string))]
          [(= pid 0)
           ;; child: only async-signal-safe work until exec
           (unless (eqv? cwd-c 0) (chdir cwd-c))
           (for-each (lambda (sig) (signal sig 0))   ; SIG_DFL
                     (list SIGINT SIGPIPE SIGCHLD SIGHUP SIGTERM 3 20 21 22))
           (sigprocmask SIG_SETMASK sigset 0)
           (execvp file argv)
           (_exit 127)]
          [else
           (let ([fd (foreign-ref 'int master 0)])
             (free master) (free ws) (free sigset)
             (unless (eqv? cwd-c 0) (free cwd-c))
             (fcntl fd F_SETFL (logor (fcntl fd F_GETFL 0) O_NONBLOCK))
             (fcntl fd F_SETFD FD_CLOEXEC)
             (values fd pid))]))))

  (define (pty-resize! fd rows cols xpixel ypixel)
    (let ([ws (make-winsize rows cols xpixel ypixel)])
      (ioctl fd TIOCSWINSZ ws)
      (free ws)))

  ;; Returns the number of bytes read, 0 when no data is available, or
  ;; #f on end of file / error (child exited).
  (define (pty-read fd bv)
    (let ([n (c-read fd bv (bytevector-length bv))])
      (cond
        [(> n 0) n]
        [(and (< n 0) (memv (errno) (list EAGAIN EINTR))) 0]
        [else #f])))

  ;; Write bytes [off, off+len) of bv; returns bytes written (maybe 0) or #f.
  (define (pty-write fd bv off len)
    (let* ([chunk (if (= off 0)
                      bv
                      (let ([c (make-bytevector len)])
                        (bytevector-copy! bv off c 0 len)
                        c))]
           [n (c-write fd chunk len)])
      (cond
        [(>= n 0) n]
        [(memv (errno) (list EAGAIN EINTR)) 0]
        [else #f])))

  (define status-buf (malloc 8))

  ;; Run PROGRAM (path and arguments) fully detached from us (double fork,
  ;; new session), optionally in directory CWD.
  (define (spawn-detached program cwd)
    (let* ([argv (make-argv program)]
           [file (foreign-ref 'uptr argv 0)]
           [cwd-c (if cwd (string->cstring cwd) 0)]
           [sigset (malloc 128)])
      (sigemptyset sigset)
      (let ([pid (fork)])
        (cond
          [(= pid 0)
           (setsid)
           (when (= 0 (fork))
             (unless (eqv? cwd-c 0) (chdir cwd-c))
             (for-each (lambda (sig) (signal sig 0))
                       (list SIGINT SIGPIPE SIGCHLD SIGHUP SIGTERM 3 20 21 22))
             (sigprocmask SIG_SETMASK sigset 0)
             (execvp file argv)
             (_exit 127))
           (_exit 0)]
          [(> pid 0) (waitpid pid status-buf 0)]
          [else (void)]))
      (free sigset)
      (unless (eqv? cwd-c 0) (free cwd-c))
      (let loop ([i 0])
        (let ([p (foreign-ref 'uptr argv (* 8 i))])
          (unless (= p 0) (free p) (loop (+ i 1)))))
      (free argv)))

  ;; Current working directory of process PID (Linux /proc), or #f.
  (define (process-cwd pid)
    (let* ([buf (malloc 4096)]
           [n (readlink (format "/proc/~a/cwd" pid) buf 4095)])
      (let ([r (and (> n 0)
                    (begin (foreign-set! 'unsigned-8 buf n 0) (cstring->string buf)))])
        (free buf)
        r)))

  (define (pty-child-exited? pid)
    (let ([r (waitpid pid status-buf WNOHANG)])
      (or (= r pid) (< r 0))))

  (define (pty-hangup! fd pid)
    (close fd)
    (kill pid SIGHUP)))
