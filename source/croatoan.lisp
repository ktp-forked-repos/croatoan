(in-package :de.anvi.croatoan)

;;; Define all macros here centrally.

(defmacro with-screen ((screen &key
                               (input-buffering nil)
                               (process-control-chars t)
                               (input-blocking t)
                               (input-echoing t)
                               (enable-fkeys t)
                               (enable-scrolling nil)
                               (insert-mode nil)
                               (enable-colors  t)
                               (use-default-colors nil)
                               (cursor-visibility t)
                               (stacked nil)
                               (color-pair nil)
                               (background nil))
                       &body body)
  "Create a screen, evaluate the forms in the body, then cleanly close the screen.

Pass any arguments to the initialisation of the screen object. The screen 
is cleared immediately after initialisation.

This macro is the main entry point for writing ncurses programs with the croatoan 
library. Do not run more than one screen at the same time."
  `(unwind-protect
        (let ((,screen (make-instance 'screen
                                      :input-buffering ,input-buffering
                                      :process-control-chars ,process-control-chars
                                      :input-blocking ,input-blocking
                                      :input-echoing  ,input-echoing
                                      :enable-fkeys   ,enable-fkeys
                                      :enable-scrolling ,enable-scrolling
                                      :insert-mode ,insert-mode
                                      :enable-colors  ,enable-colors
                                      :use-default-colors ,use-default-colors
                                      :cursor-visibility ,cursor-visibility
                                      :stacked ,stacked
                                      :color-pair ,color-pair
                                      :background ,background))

              ;; when an error is signaled and not handled, cleanly end ncurses, print the condition text
              ;; into the repl and get out of the debugger into the repl.
              ;; the debugger is annoying with ncurses apps.
              ;; add (abort) to automatically get out of the debugger.
              (*debugger-hook* #'(lambda (c h) (declare (ignore h)) (end-screen) (print c) )))

          ;; clear the display when starting up.
          (clear ,screen)

          ,@body)

     ;; cleanly exit ncurses whatever happens.
     (end-screen)))

(defmacro with-window ((win &rest options) &body body)
  "Create a window, evaluate the forms in the body, then cleanly close the window.

Pass any arguments to the initialisation of the window object.

Example:

(with-window (win :input-echoing t
  body)"
  `(let ((,win (make-instance 'window ,@options)))
     (unwind-protect
          (progn
            ,@body)
       (close ,win))))

;; see similar macro cffi:with-foreign-objects.
(defmacro with-windows (bindings &body body)
  "Create one or more windows, evaluate the forms in the body, then cleanly close the windows.

Pass any arguments to the initialisation of the window objects.

Example:

(with-windows ((win1 :input-echoing t)
               (win2 :input-echoing t))
  body)"
  (if bindings
      ;; execute the bindings recursively
      `(with-window ,(car bindings)
         ;; the cdr is the body
         (with-windows ,(cdr bindings)
           ,@body))
      ;; finally, execute the body.
      `(progn
         ,@body)))

(defmacro event-case ((window event &optional mouse-y mouse-x) &body body)
  "Window event loop, events are handled by an implicit case form.

For now, it is limited to events generated in a single window. So events
from multiple windows have to be handled separately.

In order for event-handling to work, input-buffering has to be nil.
Several control character events can only be handled when 
process-control-chars is also nil.

If input-blocking is nil, we can handle the (nil) event, i.e. what
happens between key presses.

If input-blocking is t, the (nil) event is never returned.

The main window event loop name is hard coded to event-case to be
used with return-from.

Instead of ((nil) nil), which eats 100% CPU, use input-blocking t."
  (if (and mouse-y mouse-x)
      `(loop :named event-case do
          (multiple-value-bind (,event ,mouse-y ,mouse-x)
              ;; depending on which version of ncurses is loaded, decide which event reader to use.
              #+(or sb-unicode unicode openmcl-unicode-strings) (get-wide-event ,window)
              #-(or sb-unicode unicode openmcl-unicode-strings) (get-event ,window)
              ;;(print (list ,event mouse-y mouse-x) ,window)
              (case ,event
                ,@body)))
      `(loop :named event-case do
          ;; depending on which version of ncurses is loaded, decide which event reader to use.
          (let ((,event #+(or sb-unicode unicode openmcl-unicode-strings) (get-wide-event ,window)
                        #-(or sb-unicode unicode openmcl-unicode-strings) (get-event ,window)))
            (case ,event
              ,@body)))))

(defmacro add-event-handler ((window event) &body handler-function)
  "Add the event and its handler-function to the window's event handler alist.

The handlers will be called by the run-event-loop when keyboard or mouse events occur.

The handler functions have two mandatory arguments, window and event.

For every event-loop, at least an event to exit the event loop should be assigned,
by associating it with the predefined function exit-event-loop.

If a handler for the event :default is defined, it will handle all events for which
no specific event handler has been defined.

If input-blocking of the window is set to nil, a handler for the nil event
can be defined, which will be called at a specified frame-rate between keypresses.
Here the main application state can be updated.

Alternatively, to achieve the same effect, input-blocking can be set to a specific
delay in miliseconds.

Example use:

(add-event-handler (scr #\q)
  (lambda (win event)
    (throw 'event-loop :quit)))"
  `(setf (slot-value ,window 'event-handlers)
         ;; we need to make handler-function a &body so it is indented properly by slime.
         (acons ,event ,@handler-function (slot-value ,window 'event-handlers))))

(defmacro remove-event-handler (window event)
  "Remove the event and the handler function from a windows event-handlers collection."
  `(setf (slot-value ,window 'event-handlers)
         (remove ,event (slot-value ,window 'event-handlers) :key #'car)))

(defparameter *keymaps* nil
  "An alist of available keymaps that can be read and written by get-keymap and add-keymap.")

(defun make-keymap (&rest args)
  "Take a list of keys and values, return an event handler keymap.

Currently the keymap is implemented as an alist, but will be converted
to a hash table in the future."
  (loop for (i j) on args by #'cddr
    collect (cons i j)))

(defun get-keymap (keymap-name)
  "Take a keyword denoting a keymap name, return a keymap object from the global keymap collection."
  (cdr (assoc keymap-name *keymaps*)))

(defun add-keymap (keymap-name keymap)
  "Add a keymap by its name to the global keymap collection."
  (setf *keymaps* (acons keymap-name keymap *keymaps*)))

(defun get-event-handler (object event)
  "Take an object and an event, return the handler for that event.

The keybindings alist is stored in the event-handlers slot of the object.

If no handler is defined for the event, the default event handler t is tried.
If not even a default handler is defined, the event is ignored.

If input-blocking is nil, we receive nil events in case no real events occur.
In that case, the handler for the nil event is returned, if defined.

The event pairs can be added by add-event-handler as conses: (event . #'handler).

An event should be bound to the pre-defined function exit-event-loop."
  (flet ((ev (event)
           (assoc event (slot-value object 'event-handlers))))
    (cond
      ;; Event occured and event handler is defined.
      ((and event (ev event)) (cdr (ev event)))
      ;; Event occured and a default event handler is defined.
      ;; If not even the default handler is defined, the event is ignored.
      ((and event (ev t)) (cdr (ev t)))
      ;; If no event occured and the idle handler is defined.
      ;; The event is only nil when input input-blocking is nil.
      ((and (null event) (ev nil)) (cdr (ev nil)))
      ;; If no event occured and the idle handler is not defined.
      (t nil))))

(defun run-event-loop (object &rest args)
  "Read events from the window, then call predefined event handler functions on the events.

The handlers can be added by the macro add-event-handler, or by directly setting
a predefined keymap to the window's event-handlers slot.

Args is one or more additional argument passed to the handlers.

Provide a non-local exit point so we can exit the loop from an event handler. 

One of the events must provide a way to exit the event loop by throwing 'event-loop.

The function exit-event-loop is pre-defined to perform this non-local exit."
  (catch 'event-loop
    (loop
       (let* ((window (typecase object (window object) (otherwise (.window object))))
              (event (get-wide-event window)))
         (handle-event object event args)
         ;; should a frame rate be a property of the window or of the object?
         (when (and (null event) (.frame-rate window))
           (sleep (/ 1.0 (.frame-rate window)))) ))))

(defgeneric handle-event (object event args)
  ;; the default method applies to window, field, button (for now).
  (:method (object event args)
    "Default method for all objects without a specialized method."
    (let ((handler (get-event-handler object event)))
      (when handler
        (apply handler object event args)))))

(defmethod handle-event ((form form) event args)
  (let ((handler (get-event-handler form event)))
    (if handler
        (apply handler form event args)
        (handle-event (.current-element form) event args))))

(defun exit-event-loop (&optional win event args)
  "Associate this function with an event to exit the event loop."
  (declare (ignore win event args))
  (throw 'event-loop :exit-event-loop))

(defmacro save-excursion (window &body body)
  "After executing body, return the cursor in window to its initial position."
  `(let ((pos (.cursor-position ,window)))
     ,@body
     (move ,window (car pos) (cadr pos))))
