;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;;; Simplifiy the ast by removing empty nodes and unused variables.

(in-package :sys.c)

(defun simplify (lambda)
  (simp-form lambda))

(defgeneric simp-form (form))

(defun simp-form-list (x)
  (do ((i x (cdr i)))
      ((endp i))
    (setf (car i) (simp-form (car i)))))

(defmethod simp-form ((form ast-block))
  (cond
    ;; Unused blocks get reduced to progn.
    ((eql (lexical-variable-use-count (info form)) 0)
     (change-made)
     (simp-form (body form)))
    ;; (block foo (return-from foo form)) => (block foo form)
    ((and (typep (body form) 'ast-return-from)
          (eql (info form) (info (body form))))
     (change-made)
     (setf (body form) (simp-form (value (body form))))
     form)
    (t (setf (body form) (simp-form (body form)))
       form)))

(defmethod simp-form ((form ast-function))
  form)

(defmethod simp-form ((form ast-go))
  ;; HACK: Update the tagbody location part after tagbodies have merged.
  (when (tagbody-information-p (info form))
    (setf (info form) (go-tag-tagbody (target form))))
  form)

;;; Hoist LET/M-V-B/PROGN forms out of IF tests.
;;;  (if (let bindings form1 ... formn) then else)
;;; =>
;;;  (let bindings form1 ... (if formn then else))
;;; Beware when hoisting LET/M-V-B, must not hoist special bindings.
(defun hoist-form-out-of-if (form)
  (let ((test-form (test form)))
    (typecase test-form
      (ast-let
       (when (let-binds-special-variable-p test-form)
         (return-from hoist-form-out-of-if nil))
       (ast `(let ,(bindings test-form)
               (if ,(body test-form)
                   ,(if-then form)
                   ,(if-else form)))
            form))
      (ast-multiple-value-bind
       (when (find-if (lambda (x) (typep x 'special-variable))
                      (bindings test-form))
         (return-from hoist-form-out-of-if nil))
       (ast `(multiple-value-bind ,(bindings test-form)
                 ,(value-form test-form)
               (if ,(body test-form)
                   ,(if-then form)
                   ,(if-else form)))
            form))
      (ast-progn
       (if (forms test-form)
           (ast `(progn ,@(append (butlast (forms test-form))
                                  (list `(if ,(first (last (forms test-form)))
                                             ,(if-then form)
                                             ,(if-else form)))))
                form)
           ;; No body forms, must evaluate to NIL!
           ;; Fold away the IF.
           (if-else form))))))

(defmethod simp-form ((form ast-if))
  (let ((new-form (hoist-form-out-of-if form)))
    (cond (new-form
           (change-made)
           (simp-form new-form))
          ((typep (test form) 'ast-if)
           ;; Rewrite (if (if ...) ...).
           (let ((test-form (test form)))
             (change-made)
             (simp-form (ast `(block if-escape
                                (tagbody if-tagbody
                                   (entry (if ,(test test-form)
                                              ;; Special case here to catch (if a a b), generated by OR.
                                              ,(if (eql (test test-form) (if-then test-form))
                                                   `(go then-tag if-tagbody)
                                                   `(if ,(if-then test-form)
                                                        (go then-tag if-tagbody)
                                                        (go else-tag if-tagbody)))
                                              (if ,(if-else test-form)
                                                  (go then-tag if-tagbody)
                                                  (go else-tag if-tagbody))))
                                   (then-tag (return-from if-escape ,(if-then form) if-escape))
                                   (else-tag (return-from if-escape ,(if-else form) if-escape))))
                             form))))
          ((and (typep (if-then form) 'ast-go)
                (typep (if-else form) 'ast-go)
                (eql (target (if-then form)) (target (if-else form)))
                (eql (info (if-then form)) (info (if-else form))))
           ;; Rewrite (if x (go A-TAG) (go A-TAG)) => (progn x (go A-TAG))
           (change-made)
           (simp-form (ast `(progn ,(test form) ,(if-then form))
                           form)))
          ((eql (if-then form) (if-else form))
           ;; Rewrite (if x foo foo) => (progn x foo)
           (change-made)
           (simp-form (ast `(progn ,(test form) ,(if-then form))
                           form)))
          ((typep (test form) 'ast-quote)
           ;; (if 'not-nil then else) => then
           ;; (if 'nil then else) => else
           (change-made)
           (simp-form (if (not (eql (value (test form)) 'nil))
                          (if-then form)
                          (if-else form))))
          (t
           (setf (test form) (simp-form (test form))
                 (if-then form) (simp-form (if-then form))
                 (if-else form) (simp-form (if-else form)))
           form))))

(defun pure-p (form)
  (let ((unwrapped (unwrap-the form)))
    (or (lambda-information-p unwrapped)
        (typep unwrapped 'ast-quote)
        (typep unwrapped 'ast-function)
        (and (lexical-variable-p unwrapped)
             (localp unwrapped)
             (eql (lexical-variable-write-count unwrapped) 0)))))

(defmethod simp-form ((form ast-let))
  ;; Merge nested LETs when possible, do not merge special bindings!
  (do ((nested-form (body form) (body form)))
      ((or (not (typep nested-form 'ast-let))
           (let-binds-special-variable-p form)
           (and (bindings nested-form)
                (typep (first (first (bindings nested-form))) 'special-variable))))
    (change-made)
    (if (null (bindings nested-form))
        (setf (body form) (body nested-form))
        (setf (bindings form) (nconc (bindings form) (list (first (bindings nested-form))))
              (bindings nested-form) (rest (bindings nested-form)))))
  ;; Remove unused values with no side-effects.
  (setf (bindings form) (remove-if (lambda (b)
                                     (let ((var (first b))
                                           (val (second b)))
                                       (cond ((and (lexical-variable-p var)
                                                   (pure-p val)
                                                   (eql (lexical-variable-use-count var) 0))
                                              (change-made)
                                              t)
                                             (t nil))))
                                   (bindings form)))
  (dolist (b (bindings form))
    (setf (second b) (simp-form (second b))))
  (setf (body form) (simp-form (body form)))
  ;; Rewrite (let (... (foo ([progn,let] x y)) ...) ...) to (let (...) ([progn,let] x (let ((foo y) ...) ...))) when possible.
  (when (not (let-binds-special-variable-p form))
    (loop
       for binding-position from 0
       for (variable initform) in (bindings form)
       when (typep initform 'ast-progn)
       do
         (change-made)
         (return-from simp-form
           (ast `(let ,(subseq (bindings form) 0 binding-position)
                   (progn
                     ,@(butlast (ast-forms initform))
                     (let ((,variable ,(first (last (ast-forms initform))))
                           ,@(subseq (bindings form) (1+ binding-position)))
                       ,(ast-body form))))
                form))
       when (and (typep initform 'ast-let)
                 (not (let-binds-special-variable-p initform)))
       do
         (change-made)
         (return-from simp-form
           (ast `(let (,@(subseq (bindings form) 0 binding-position)
                       ,@(bindings initform)
                       (,variable ,(ast-body initform))
                       ,@(subseq (bindings form) (1+ binding-position)))
                   ,(ast-body form))
                form))))
  ;; Remove the LET if there are no values.
  (cond ((bindings form)
         form)
        (t
         (change-made)
         (body form))))

(defun let-binds-special-variable-p (let-form)
  (some (lambda (x) (typep (first x) 'special-variable))
        (bindings let-form)))

(defmethod simp-form ((form ast-multiple-value-bind))
  ;; If no variables are used, or there are no variables then
  ;; remove the form.
  (cond ((every (lambda (var)
                  (and (lexical-variable-p var)
                       (zerop (lexical-variable-use-count var))))
                (bindings form))
         (change-made)
         (simp-form (ast `(progn ,(value-form form)
                                 ,(body form))
                         form)))
        ;; M-V-B forms with only one variable can be lowered to LET.
        ((and (bindings form)
              (every (lambda (var)
                       (and (lexical-variable-p var)
                            (zerop (lexical-variable-use-count var))))
                     (rest (bindings form))))
         (change-made)
         (simp-form (ast `(let ((,(first (bindings form)) ,(value-form form)))
                            ,(body form))
                         form)))
        ;; Use an inner LET form to bind any special variables.
        ((some (lambda (x) (typep x 'special-variable)) (bindings form))
         (change-made)
         (let* ((specials (remove-if-not (lambda (x) (typep x 'special-variable))
                                         (bindings form)))
                (replacements (loop
                                 for s in specials
                                 collect (make-instance 'lexical-variable
                                                        :inherit s
                                                        :name (name s)
                                                        :definition-point *current-lambda*
                                                        :use-count 1)))
                ;; Also doubles up as an alist mapping specials to replacements.
                (bindings (mapcar #'list specials replacements)))
           (ast `(multiple-value-bind
                       ,(mapcar (lambda (var)
                                  (if (typep var 'special-variable)
                                      (second (assoc var bindings))
                                      var))
                                (bindings form))
                     ,(value-form form)
                     (let ,bindings
                       ,(simp-form (body form))))
                form)))
        (t (setf (value-form form) (simp-form (value-form form))
                 (body form) (simp-form (body form)))
           form)))

(defmethod simp-form ((form ast-multiple-value-call))
  (setf (function-form form) (simp-form (function-form form))
        (value-form form) (simp-form (value-form form)))
  form)

(defmethod simp-form ((form ast-multiple-value-prog1))
  (setf (value-form form) (simp-form (value-form form))
        (body form) (simp-form (body form)))
  (cond ((typep (value-form form) 'ast-progn)
         ;; If the first form is a PROGN, then hoist all but the final value out.
         (change-made)
         (ast `(progn ,@(butlast (forms (value-form form)))
                      (multiple-value-prog1 ,(car (last (forms (value-form form))))
                        ,(body form)))
              form))
        ((typep (value-form form) 'ast-multiple-value-prog1)
         ;; If the first form is a M-V-PROG1, then splice it in.
         (change-made)
         (ast `(multiple-value-prog1 ,(value-form (value-form form))
                 (progn ,(body (value-form form))
                        ,(body form)))
              form))
        ((typep (body form) '(or ast-quote ast-function lexical-variable lambda-information))
         ;; If the body form is mostly constant, then kill this completely.
         (change-made)
         (value-form form))
        (t form)))

(defun simp-progn-body (x)
  ;; Merge nested progns, remove unused quote/function/lambda/variable forms
  ;; and eliminate code after return-from/go.
  (do* ((i x (rest i))
        (result (cons nil nil))
        (tail result))
       ((endp i)
        (cdr result))
    (let ((form (simp-form (first i))))
      (cond ((and (typep form 'ast-progn)
                  (forms form))
             ;; Non-empty PROGN.
             (change-made)
             ;; Rewrite ((progn v1 ... vn) . xn) to (v1 .... vn . xn).
             (setf (cdr tail) (simp-progn-body (forms form))
                   tail (last tail)))
            ((and (typep form 'ast-progn)
                  (not (forms form)))
             ;; Empty progn. Replace with 'NIL if at end.
             (change-made)
             (when (rest i)
               (setf (cdr tail) (cons (ast `(quote nil)) nil)
                     tail (cdr tail))))
            ((and (rest i) ; not at end.
                  (or (typep form 'ast-quote)
                      (typep form 'ast-function)
                      (lexical-variable-p form)
                      (lambda-information-p form)))
             ;; This is a constantish value not at the end.
             ;; Remove it.
             (change-made))
            (t
             (setf (cdr tail) (cons form nil)
                   tail (cdr tail)))))))

(defmethod simp-form ((form ast-progn))
  (let ((new-forms (simp-progn-body (forms form))))
    (cond ((endp new-forms)
           ;; Flush empty PROGNs.
           (change-made)
           (ast `(quote nil) form))
          ((endp (rest new-forms))
           ;; Reduce single form PROGNs.
           (change-made)
           (first new-forms))
          (t
           (setf (forms form) new-forms)
           form))))

(defmethod simp-form ((form ast-quote))
  form)

(defmethod simp-form ((form ast-return-from))
  (setf (value form) (simp-form (value form))
        (info form) (simp-form (info form)))
  form)

(defmethod simp-form ((form ast-setq))
  (setf (value form) (simp-form (value form)))
  form)

(defmethod simp-form ((form ast-tagbody))
  ;; Remove unused go-tags.
  (setf (tagbody-information-go-tags (info form))
        (remove-if (lambda (x) (eql (go-tag-use-count x) 0))
                   (tagbody-information-go-tags (info form))))
  (setf (statements form) (remove-if (lambda (x) (eql (go-tag-use-count (first x)) 0))
                                     (statements form)))
  ;; Try to merge any nested TAGBODYs.
  ;; Do this before simplification, because GO forms will need to be updated.
  (let ((new-stmts '()))
    (loop
       for (go-tag statement) in (statements form)
       do (typecase statement
            (ast-progn
             (cond ((some (lambda (x) (typep x 'ast-tagbody)) (forms statement))
                    ;; Contains at least one nested TAGBODY.
                    (let ((current-go-tag go-tag)
                          (accum '()))
                      (dolist (subform (forms statement))
                        (typecase subform
                          (ast-tagbody
                           ;; Reached a tagbody.
                           ;; Jump from the current tag to the tagbody's entry tag.
                           (push (ast `(go ,(first (first (statements subform))) ,(info form))
                                      subform)
                                 accum)
                           (incf (go-tag-use-count (first (first (statements subform)))))
                           ;; Finish accumulating the forms before this tagbody.
                           (push (list current-go-tag (ast `(progn ,@(reverse accum)) subform)) new-stmts)
                           ;; Create a new go-tag that is *after* this tagbody.
                           (setf current-go-tag (make-instance 'go-tag
                                                               :inherit subform
                                                               :name (gensym "tagbody-resume")
                                                               :use-count 1
                                                               :tagbody (info form))
                                 accum '())
                           (push current-go-tag (tagbody-information-go-tags (info form)))
                           ;; Splice tagbody in, and after each statement add a GO to
                           ;; the resume tag.
                           (loop
                              for (new-go-tag new-statement) in (statements subform)
                              do
                                (push new-go-tag (tagbody-information-go-tags (info form)))
                                (setf (go-tag-tagbody new-go-tag) (info form))
                                (incf (go-tag-use-count current-go-tag))
                                (push (list new-go-tag (ast `(progn
                                                               ,new-statement
                                                               (go ,current-go-tag ,(info form)))
                                                            new-statement))
                                      new-stmts)))
                          (t ;; Normal form, accumulate it.
                           (push subform accum))))
                      ;; Finish the current tag.
                      (push (list current-go-tag (ast `(progn ,@(reverse accum) 'nil) statement)) new-stmts)))
                   (t (push (list go-tag statement) new-stmts))))
            (ast-tagbody
             ;; Get this one.
             (push (list go-tag (ast `(go ,(first (first (statements statement))) ,(info form)) statement)) new-stmts)
             (incf (go-tag-use-count (first (first (statements statement)))))
             (loop
                for (new-go-tag new-statement) in (statements statement)
                do
                  (push new-go-tag (tagbody-information-go-tags (info form)))
                  (setf (go-tag-tagbody new-go-tag) (info form))
                  (push (list new-go-tag new-statement) new-stmts)))
            (t (push (list go-tag statement) new-stmts))))
    (setf (statements form) (reverse new-stmts)))
  ;; Simplify forms.
  (setf (statements form) (loop
                             for (go-tag statement) in (statements form)
                             collect (list go-tag (simp-form statement))))
  ;; If the entry go-tag has one use, and there aren't any more statements, then
  ;; reduce this to a progn.
  (cond ((and (eql (go-tag-use-count (first (first (statements form)))) 1)
              (endp (rest (statements form))))
         (change-made)
         (ast `(progn
                 ,(second (first (statements form)))
                 'nil)
              form))
        (t form)))

(defun values-type-p (type)
  (and (consp type)
       (eql (first type) 'values)))

(defun merge-the-types (type-1 type-2)
  (cond ((equal type-1 type-2)
         type-1)
        ((or (values-type-p type-1)
             (values-type-p type-2))
         (when (not (values-type-p type-1))
           (setf type-1 `(values ,type-1)))
         (when (not (values-type-p type-2))
           (setf type-2 `(values ,type-2)))
         (do ((i (rest type-1) (rest i))
              (j (rest type-2) (rest j))
              (result '()))
             ((and (endp i)
                   (endp j))
              `(values ,@(reverse result)))
           (push (merge-the-types (if i (first i) 't)
                                  (if j (first j) 't))
                 result)))
        (t
         `(and ,type-1 ,type-2))))

(defmethod simp-form ((form ast-the))
  (cond ((compiler-subtypep 't (the-type form))
         (change-made)
         (simp-form (value form)))
        ((typep (value form) 'ast-the)
         (change-made)
         (setf (the-type form) (merge-the-types (the-type form)
                                                (the-type (value form)))
               (value form) (simp-form (value (value form))))
         form)
        ((and (typep (value form) 'ast-let)
              (not (typep (ast-body (value form)) 'ast-the)))
         ;; Turn (the ... (let (...) ...)) inside-out: (let (...) (the ... ...))
         (change-made)
         (setf (ast-body (value form)) (ast `(the ,(the-type form)
                                                  ,(ast-body (value form)))
                                            form))
         (setf (value form) (simp-form (value form)))
         form)
        ((typep (value form) 'ast-if)
         ;; Push type declarations into IF arms.
         (when (not (typep (if-then (value form)) 'ast-the))
           (change-made)
           (setf (if-then (value form)) (ast `(the ,(the-type form)
                                                   ,(if-then (value form)))
                                             (if-then (value form)))))
         (when (not (typep (if-else (value form)) 'ast-the))
           (change-made)
           (setf (if-else (value form)) (ast `(the ,(the-type form)
                                                   ,(if-else (value form)))
                                             (if-else (value form)))))
         (setf (value form) (simp-form (value form)))
         form)
        (t
         (setf (value form) (simp-form (value form)))
         form)))

(defmethod simp-form ((form ast-unwind-protect))
  (setf (protected-form form) (simp-form (protected-form form))
        (cleanup-function form) (simp-form (cleanup-function form)))
  form)

(defun eq-comparable-p (value)
  (or (not (numberp value))
      (fixnump value) ;; Use fixnump, not the type fixnum to avoid x-compiler problems.
      (typep value 'single-float)))

(defun simp-eql (form)
  (simp-form-list (arguments form))
  (when (eql (list-length (arguments form)) 2)
    ;; (eql constant non-constant) => (eql non-constant constant)
    (when (and (quoted-form-p (first (arguments form)))
               (not (quoted-form-p (second (arguments form)))))
      (change-made)
      (rotatef (first (arguments form)) (second (arguments form))))
    ;; (eql x eq-comparable-constant) => (eq x eq-comparable-constant)
    (when (and (quoted-form-p (second (arguments form)))
               (eq-comparable-p (value (second (arguments form)))))
      (change-made)
      (setf (name form) 'eq)))
  form)

(defun simp-ash (form)
  (simp-form-list (arguments form))
  (cond ((and (eql (list-length (arguments form)) 2)
              (or (and (typep (second (arguments form)) 'ast-the)
                       (match-optimize-settings form '((= safety 0) (= speed 3)))
                       (compiler-subtypep (ast-the-type (second (arguments form))) '(eql 0)))
                  (and (quoted-form-p (second (arguments form)))
                       (eql (value (second (arguments form))) 0))))
         ;; (ash value 0) => (progn (type-check value integer) value)
         (change-made)
         (return-from simp-ash
           (if (match-optimize-settings form '((= safety 0) (= speed 3)))
               (ast `(let ((value ,(first (arguments form))))
                       (progn
                         ,(second (arguments form))
                         value))
                    form)
               (ast `(let ((value ,(first (arguments form))))
                       (progn
                         ,(second (arguments form))
                         (if (call integerp value)
                             value
                             (call sys.int::raise-type-error value 'integer))))
                    form))))
        ((and (eql (list-length (arguments form)) 2)
              (quoted-form-p (second (arguments form)))
              (integerp (value (second (arguments form)))))
         ;; (ash value known-count) => left-shift or right-shift.
         (change-made)
         (cond ((plusp (value (second (arguments form))))
                (setf (name form) 'mezzano.runtime::left-shift))
               (t
                (setf (name form) 'mezzano.runtime::right-shift
                      (arguments form) (list (first (arguments form))
                                             (make-instance 'ast-quote
                                                            :inherit form
                                                            :value (- (value (second (arguments form))))))))))
        ((and (eql (list-length (arguments form)) 2)
              (match-optimize-settings form '((= safety 0) (= speed 3)))
              (typep (second (arguments form)) 'ast-the)
              (compiler-subtypep (ast-the-type (second (arguments form))) '(integer 0)))
         ;; (ash value known-non-negative-integer) => left-shift
         (change-made)
         (setf (name form) 'mezzano.runtime::left-shift))
        ((and (eql (list-length (arguments form)) 2)
              (match-optimize-settings form '((= safety 0) (= speed 3)))
              (typep (second (arguments form)) 'ast-the)
              (compiler-subtypep (ast-the-type (second (arguments form))) '(integer * 0)))
         ;; (ash value known-non-positive-integer) => right-shift
         (change-made)
         (setf (name form) 'mezzano.runtime::right-shift
               (arguments form) (list (first (arguments form))
                                      (ast `(call sys.int::binary-- '0 ,(second (arguments form)))
                                           form)))))
  form)

(defparameter *mod-n-arithmetic-functions*
  '(sys.int::binary-+ sys.int::binary--
    sys.int::binary-* sys.int::%truncate rem
    sys.int::binary-logior sys.int::binary-logxor sys.int::binary-logand
    mezzano.runtime::%fixnum-left-shift))

(defun mod-n-transform-candidate-p (value mask)
  ;; Mask must be a known positive power-of-two minus 1 fixnum.
  (when (not (and (typep mask 'ast-quote)
                  (typep (ast-value mask) 'fixnum)
                  (> (ast-value mask) 0)
                  (zerop (logand (ast-value mask)
                                 (1+ (ast-value mask))))))
    (return-from mod-n-transform-candidate-p
      nil))
  ;; The value must be a call to one of the arithmetic functions.
  ;; Both sides must be fixnums. This will cause the fixnum arithmetic
  ;; transforms to fire, and the calls to be transformed to their
  ;; fixnum-appropriate functions.
  (when (not (and (typep value 'ast-call)
                  (member (name value) *mod-n-arithmetic-functions*)
                  (eql (length (arguments value)) 2)
                  (match-transform-argument 'fixnum (first (arguments value)))
                  (match-transform-argument 'fixnum (second (arguments value)))))
    (return-from mod-n-transform-candidate-p
      nil))
  t)

;;; Fast(ish) mod-n arithmetic.
;;; (logand (1- some-known-fixnum-power-of-two) (+ (the fixnum foo) (the fixnum bar)))
;;;   =>
;;; (logand (1- some-known-fixnum-power-of-two) (the fixnum (+ (the fixnum foo) (the fixnum bar))))
;;; Any fixnum LOGAND a fixnum will produce a fixnum result.
;;; This relies on the arithmetic function being transformed to a function
;;; that really does only produce a fixnum result.
(defun simp-logand (form)
  (let ((lhs (first (arguments form)))
        (rhs (second (arguments form))))
    (cond ((mod-n-transform-candidate-p rhs lhs)
           ;; Insert appropriate THE form.
           (change-made)
           (setf (second (arguments form)) (ast `(the fixnum ,rhs)
                                                rhs)))
          ((mod-n-transform-candidate-p lhs rhs)
           ;; Insert appropriate THE form.
           (change-made)
           (setf (first (arguments form)) (ast `(the fixnum ,lhs)
                                               lhs))))
    form))

(defmethod simp-form ((form ast-call))
  (simp-form-list (arguments form))
  (cond ((eql (name form) 'eql)
         (simp-eql form))
        ((eql (name form) 'ash)
         (simp-ash form))
        ((and (member (name form) '(sys.int::binary-logand %fast-fixnum-logand))
              (eql (length (arguments form)) 2)
              (match-optimize-settings form '((= safety 0) (= speed 3))))
         (simp-logand form))
        ;; (%coerce-to-callable 'foo) => #'foo
        ((and (eql (name form) 'sys.int::%coerce-to-callable)
              (eql (length (arguments form)) 1)
              (typep (unwrap-the (first (arguments form))) 'ast-quote)
              (symbolp (value (first (arguments form)))))
         (change-made)
         (ast `(function ,(value (first (arguments form))))
              form))
        ;; (%coerce-to-callable #'foo) => #'foo
        ((and (eql (name form) 'sys.int::%coerce-to-callable)
              (eql (length (arguments form)) 1)
              (typep (unwrap-the (first (arguments form))) 'ast-function))
         (change-made)
         (first (arguments form)))
        ;; (%coerce-to-callable (lambda ...)) => (lambda ...)
        ((and (eql (name form) 'sys.int::%coerce-to-callable)
              (eql (length (arguments form)) 1)
              (typep (unwrap-the (first (arguments form))) 'lambda-information))
         (change-made)
         (first (arguments form)))
        ;; (%apply #'foo (list ...)) => (foo ...)
        ((and (eql (name form) 'mezzano.runtime::%apply)
              (eql (length (arguments form)) 2)
              (typep (unwrap-the (first (arguments form))) 'ast-function)
              (typep (second (arguments form)) 'ast-call)
              (eql (name (second (arguments form))) 'list))
         (change-made)
         (setf (name form) (ast-name (unwrap-the (first (arguments form))))
               (arguments form) (arguments (second (arguments form))))
         (simp-form form))
        ;; (%funcall #'name ...) -> (name ...)
        ((and (eql (name form) 'mezzano.runtime::%funcall)
              (typep (unwrap-the (first (arguments form))) 'ast-function))
         (change-made)
         (simp-form-list (rest (arguments form)))
         (ast `(call ,(name (unwrap-the (first (arguments form))))
                     ,@(rest (arguments form))) form))
        ;; (funcall fn ...) = (%funcall (%coerce-to-callable fn) ...)
        ((and (eql (name form) 'funcall)
              (consp (arguments form)))
         (change-made)
         (ast `(call mezzano.runtime::%funcall
                     (call sys.int::%coerce-to-callable
                           ,(first (arguments form)))
                     ,@(rest (arguments form)))
              form))
        (t
         ;; Rewrite (foo ... ([progn,let] x y) ...) to ([progn,let] x (foo ... y ...)) when possible.
         (loop
            for arg-position from 0
            for arg in (arguments form)
            when (typep arg 'ast-progn)
            do
              (change-made)
              (return-from simp-form
                (ast `(progn
                        ,@(butlast (ast-forms arg))
                        (call ,(ast-name form)
                              ,@(subseq (arguments form) 0 arg-position)
                              ,(first (last (ast-forms arg)))
                              ,@(subseq (arguments form) (1+ arg-position))))
                     form))
            when (and (typep arg 'ast-let)
                      (not (let-binds-special-variable-p arg)))
            do
              (change-made)
              (return-from simp-form
                (ast `(let ,(ast-bindings arg)
                        (call ,(ast-name form)
                              ,@(subseq (arguments form) 0 arg-position)
                              ,(ast-body arg)
                              ,@(subseq (arguments form) (1+ arg-position))))
                     form))
            ;; Bail when a non-pure arg is seen. Arguments after this one can't safely be hoisted.
            when (not (pure-p arg))
            do (return))
         form)))

(defmethod simp-form ((form ast-jump-table))
  (setf (value form) (simp-form (value form)))
  (setf (targets form) (mapcar #'simp-form (targets form)))
  form)

(defmethod simp-form ((form lexical-variable))
  form)

(defmethod simp-form ((form lambda-information))
  (let ((*current-lambda* form))
    (dolist (arg (lambda-information-optional-args form))
      (setf (second arg) (simp-form (second arg))))
    (dolist (arg (lambda-information-key-args form))
      (setf (second arg) (simp-form (second arg))))
    (setf (lambda-information-body form) (simp-form (lambda-information-body form))))
  form)
