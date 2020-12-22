;;;; src/debugger.lisp

(in-package #:portable-condition-system)

;;; DEFINE-COMMAND

(defgeneric run-debugger-command (command stream condition &rest arguments)
  (:documentation "Executes the provided debugger command, reading input from
and printing output to the provided stream. The condition object the debugger
was entered with and optional command arguments are available for use within
the command itself."))

(defvar *skip-debugger-prefix* nil
  "Whether or not to avoid printing the debugger line prefix when
  executing a command.")

(defmethod run-debugger-command :around (command stream condition &rest arguments)
  "Prefixes each line of output with semicolons unless told not to."
  (cond
    (*skip-debugger-prefix*
     (call-next-method))
    (t
     (fresh-line)
     (pprint-logical-block (stream nil :per-line-prefix ";; ")
       (apply #'call-next-method command stream condition arguments)))))

(defmethod run-debugger-command (command stream condition &rest arguments)
  "Informs the user that the provided debugger command was not recognized."
  (declare (ignore arguments))
  (format stream "~&~S is not a recognized command.
Type :HELP for available commands." command))

(defmacro define-command (name (stream condition &rest arguments) &body body)
  "Accepts a command name (which should be a keyword) and generates a DEFMETHOD
form in which the stream, condition, and argument variables are available for
use inside the method body."
  (check-type name keyword)
  (let ((command-var (gensym "COMMAND"))
        (arguments-var (gensym "ARGUMENTS"))
        (stream-var (gensym "STREAM"))
        (condition-var (gensym "CONDITION-VAR"))
    (multiple-value-bind (real-body declarations documentation)
        (parse-body body :documentation t)
      `(defmethod run-debugger-command
           ((,command-var (eql ,name)) ,stream-var ,condition-var &rest ,arguments-var)
         ,@(when documentation `(,documentation))
         (destructuring-bind (,stream ,condition ,@arguments)
             (list* ,stream-var ,condition-var ,arguments-var)
           ,@declarations
           ,@real-body)))))

;;; Debugger commands

(defvar *debug-level* 0
  "A variable holding the current debugger level, rebound dynamically on each
debugger entry.")

(defmethod run-debugger-command :around
    ((command (eql :eval)) stream condition &rest arguments)
  "Prevents eval commands from having semicolons printed before them."
  (declare (ignore stream condition arguments))
  (let ((*skip-debugger-prefix* t))
    (call-next-method)))

(define-command :eval (stream condition &optional form)
  "Evaluates a form. The form may be provided as an optional argument;
otherwise, it read from the provided stream."
  (let ((level *debug-level*))
    (with-simple-restart (abort "Return to debugger level ~D." level)
      (let* ((real-form (or form (read stream)))
             (- real-form)
             (values (multiple-value-list (eval real-form))))
        (format stream "~&~{~S~^~%~}" values)
        (values values real-form)))))

(define-command :report (stream condition &optional (level *debug-level*))
  "Informs the user that the debugger has been entered and reports the condition
object the debugger was entered with."
  (format stream "~&Debugger level ~D entered on ~_~S"
          level (type-of condition))
  (handler-case (format stream "~&~A" condition)
    (error () (format stream "~&#<error while reporting condition>"))))

(define-command :condition (stream condition)
  "Returns the condition object that the debugger was entered with."
  (run-debugger-command :eval stream condition condition))

(defun restart-max-name-length (restarts)
  "Returns the length of the longest name from the provided restarts."
  (flet ((name-length (restart) (length (string (restart-name restart)))))
    (if restarts (reduce #'max (mapcar #'name-length restarts)) 0)))

(define-command :restarts (stream condition)
  "Prints a list of available restarts."
  (let ((restarts (compute-restarts condition)))
    (fresh-line stream)
    (cond (restarts
           (format stream "Available restarts:")
           (loop with max-name-length = (restart-max-name-length restarts)
                 for i from 0
                 for restart in restarts
                 for restart-name = (or (restart-name restart) "")
                 do (format stream "~&~2,' D: [~vA] "
                            i max-name-length restart-name)
                    (handler-case
                        (format stream "~@<~A~:>" restart)
                      (error ()
                        (format stream "#<error while reporting restart>")))))
          (t (format stream "~&No available restarts.")))))

(define-command :restart (stream condition &optional n)
  "Invokes a particular restart."
  (let* ((n (or n (read stream)))
         (restart (nth n (compute-restarts condition))))
    (if restart
        (invoke-restart-interactively restart)
        (format stream "~&There is no restart with number ~D." n))))

(defun debugger-invoke-restart (name stream condition)
  "Finds and invokes a restart with the given name; if no such restart is
available, informs the user about that fact."
  (let ((restart (find-restart name condition)))
    (if restart
        (invoke-restart-interactively restart)
        (format stream "~&;; There is no active ~A restart." name))))

(define-command :abort (stream condition)
  "Finds and invokes the ABORT restart; if no such restart is available, informs
the user about that fact."
  (debugger-invoke-restart 'abort stream condition))

(define-command :q (stream condition)
  "Shorthand for :ABORT."
  (debugger-invoke-restart 'abort stream condition))

(define-command :continue (stream condition)
  "Finds and invokes the CONTINUE restart; if no such restart is available,
informs the user about that fact."
  (debugger-invoke-restart 'continue stream condition))

(define-command :c (stream condition)
  "Shorthand for :CONTINUE."
  (debugger-invoke-restart 'continue stream condition))

(defvar *help-hooks* '()
  "A list of hooks that are called when the :HELP debugger command is invoked.
Each hook must be a function that accepts a condition object that the debugger
was entered with and a stream that the hook should print to.")

(define-command :help (stream condition)
  "Prints the debugger help."
  (format stream "~&~
This is the standard debugger of the Portable Condition System.
The debugger read-eval-print loop supports the standard REPL variables:
  *   **   ***   +   ++   +++   /   //   ///   -

Available debugger commands:
 :HELP              Show this text.
 :EVAL <form>       Evaluate a form typed after the :EVAL command.
 :REPORT            Report the condition the debugger was invoked with.
 :CONDITION         Return the condition the debugger was invoked with.
 :RESTARTS          Print available restarts.
 :RESTART <n>, <n>  Invoke a restart with the given number.")
  (when (find-restart 'abort condition)
    (format stream "~& :ABORT, :Q         Invoke an ABORT restart.~%"))
  (when (find-restart 'continue condition)
    (format stream "~& :CONTINUE, :C      Invoke a CONTINUE restart.~%"))
  (dolist (hook *help-hooks*)
    (funcall hook condition stream))
  (format stream "~%~%Any non-keyword non-integer form is evaluated.~%"))

;;; Debugger implementation

(defun read-eval-print-command (stream condition)
  "Implements a single read-eval-print pass of the debugger REPL. Keywords are
treated as debugger commands and integers are treated as arguments to
:RESTART."
  (format stream "~&[~D] Debug> "*debug-level*)
  (let* ((thing (read stream)))
    (multiple-value-bind (values actual-thing)
        (typecase thing
          (keyword (run-debugger-command thing stream condition))
          (integer (run-debugger-command :restart stream condition thing))
          (t (run-debugger-command :eval stream condition thing)))
      (unless actual-thing (setf actual-thing thing))
      (prog1 values
        (shiftf /// // / values)
        (shiftf *** ** * (first values))
        (shiftf +++ ++ + actual-thing)))))

(defun standard-debugger (condition &optional (stream *debug-io*))
  "Implements the standard debugger."
  (let ((*debug-level* (1+ *debug-level*)))
    (run-debugger-command :report stream condition)
    (format stream "~&;; Type :HELP for available commands.~%")
    (loop (read-eval-print-command stream condition))))

;;; Debugger interface

(defvar *debugger-hook* nil
  "If set, it is called as a function before entry into the debugger with two
arguments: the condition object that the debugger is invoked with, and itself.")

(defgeneric invoke-debugger (condition)
  (:documentation "Invokes the debugger with the provided condition object."))

(defmethod invoke-debugger ((condition condition))
  "If the debugger hook is set, calls it with the condition object and itself.
Then, enters the standard debugger."
  (when *debugger-hook*
    (let ((hook *debugger-hook*)
          (*debugger-hook* nil))
      (funcall hook condition hook)))
  (standard-debugger condition))

(defun break (&optional (format-control "Break") &rest format-arguments)
  "Binds *debugger-hook* to NIL, establishes a CONTINUE restart, and invokes the
debugger with a condition object whose report is constructed from the optional
format control and format arguments."
  (let ((*debugger-hook* nil))
    (with-simple-restart (continue "Return from BREAK.")
      (invoke-debugger
       (make-condition 'simple-condition
                       :format-control format-control
                       :format-arguments format-arguments))))
  nil)
