
(in-package :djula)

; processing {{variables}}

(defun .parse-filter-string (string)
  "takes a string like:

   \" truncatechars:\"30\" \"

and turns it into:

   (:tuncatechars 30)
"
  (let ((colon (position #\: string)))
    (if colon
	(list (.keyword (subseq string 0 colon))
	      (string-trim '(#\") (subseq string (1+ colon))))
	(list (.keyword string)))))

(defun .parse-variable-phrase (string)
  "takes a string like:

   \" foo.bar.baz.2\"

and turns it into:

   (:foo :bar :baz 2)
"
  (flet ((% (%)
	   (if (every 'digit-char-p %)
	       (parse-integer %)
	       (.keyword %))))
    (let ((dot (position #\. string)))
      (if dot
	  (list* (% (subseq string 0 dot)) (.parse-variable-phrase (subseq string (1+ dot))))
	  (list (% string))))))

(defun .parse-variable-clause (unparsed-string)
  "takes a string like:

   \" foo.bar.baz.2 | truncatechars:\"30\" | upper \"

and turns it into:

   ((:foo :bar :baz 2) (:truncatechars 30) (:upper))
"
  (destructuring-bind (var . filter-strings)
      (mapcar (f_ (string-trim '(#\space #\tab #\newline #\return) _))
	      (split-sequence:split-sequence #\| unparsed-string))
    (cons (.parse-variable-phrase var) (mapcar '.parse-filter-string filter-strings))))

(def-token-processor :unparsed-variable (unparsed-string) rest
  ":PARSED-VARIABLE tokens are parsed into :VARIABLE tokens by PROCESS-TOKENS"
  `((:variable ,@(.parse-variable-clause unparsed-string)) ,@(process-tokens rest)))

; compiling {{variables}}

(defun .apply-filters (string filters)
  (if filters
      (destructuring-bind ((name . maybe-arg) . rest) filters
	(with-template-error (template-error-string "There was an error applying the filter ~A" name)
	  (let ((fn (get name 'filter)))
	    (if (null fn)
		(template-error-string "Unknown filter ~A" name)
		(.apply-filters (apply fn string maybe-arg) rest)))))
      string))

(defun .apply-keys/indexes (thing keys/indexes)
  (if (null keys/indexes)
      thing
      (destructuring-bind (1st . rest) keys/indexes
	(with-template-error (values nil
				     (template-error-string "There was an error while accessing the ~A ~S of the object ~S"
							    (if (numberp 1st)
								"index"
								"attribute")
							    1st
							    thing))
	  (if (numberp 1st)
	      (.apply-keys/indexes (nth (1- 1st) thing) rest)
	      (let ((a (assoc 1st thing)))
		(if a
		    (.apply-keys/indexes (rest a) rest)
		    nil)))))))

(defun .getf-v-plist (v-plist indicator)
  "like .GETF but :|.| keys are considered to be \"splices\"

   (.getf-v-plist '(:foo 1 :bar 2 :baz 3) :baz)

    -> 3, T

   (.getf-v-plist '(:foo 1 :. (:bar 2 :baz \"nested\") :baz 3) :baz)

   -> \"nested\", T
"
  (when v-plist
    (destructuring-bind (k v . rest) v-plist
      (if (eql k indicator)
	  (values v v-plist)
	  (if (eq k :.)
	      (multiple-value-bind (val present-p) (.getf-v-plist v indicator)
		(if present-p
		    (values val present-p)
		    #1=(.getf-v-plist rest indicator)))
	      #1#)))))

(defun get-variable (name)
  "takes a variable `NAME' and returns:

   1. the value of `NAME'
   2. any error string generated by the lookup [if there is an error string then the
      lookup was unsuccessful]
"
  (macrolet ((ret (form)
	       `(return-from get-variable ,form))
	     (with-safe ((fmt-string &rest fmt-args) &body body)
	       `(with-template-error (ret (values nil (template-error-string ,fmt-string ,@fmt-args)))
		  ,@body)))

    ;; first look in *TEMPLATE-ARGUMENTS*
    (with-safe ("There was an error looking up the variable ~A in *TEMPLATE-ARGUMENTS*" name)
      (multiple-value-bind (v present-p) (.getf-v-plist *template-arguments* name)
	(if present-p
	    (ret v))))

    ;; then maybe look in *KNOWN-EXAMPLE-TABLES*
    (when *use-example-values-p*
      (with-safe ("There was an error looking up the variable ~A in an example table" name)

	(dolist (d *known-example-tables*)
	  (destructuring-bind (path . plist) d
	    (multiple-value-bind (v present-p)
		(.getf (if *template-ffc*
			   (cl-ffc:ffc-call *template-ffc* path)
			   plist)
		       name)
	      (if present-p
		  (ret v)))))))

    ;; else can't find it
    (values nil (template-error-string "Invalid variable ~A" name))))


(defun .resolve-variable-phrase (list)
"takes a list starting wise a variable and ending with 0 or more keys or indexes [this
is a direct translation from the dot (.) syntax] and returns two values:

   1. the result [looking up the var and applying index/keys]
   2. an error string if something went wrond [note: if there is an error string then
the result probably shouldn't be considered useful."
  (destructuring-bind (var . keys/indexes) list
    (multiple-value-bind (val error-string) (get-variable var)
      (if error-string
	  (or *template-string-if-invalid*
	      (values val error-string))
	  (multiple-value-bind (val1 error-string)
	      (.apply-keys/indexes val keys/indexes)
	    (if error-string
		(values val1 error-string)
		val1))))))

(def-token-compiler :variable (variable-phrase &rest filters)

  ;; check to see if the "dont-escape" filter is used
  (let ((dont-escape (find '(:safe)
			   filters
			   :test 'equal)))
    (if dont-escape 
	(logv:format-log "danger! non html-escaped variable ~A" (first variable-phrase)))

    ;; return a function that resolves the variable-phase and applies the filters
    (f0 (multiple-value-bind (ret error-string) (.resolve-variable-phrase variable-phrase)
	  (if error-string
	      (with-template-error error-string
		(error error-string))
	      (.apply-filters (if dont-escape
				  #1=(princ-to-string (or ret ""))
				  (djula-html-escape #1#))
			      filters))))))
; defining filters

(defmacro def-filter (name args &body body)
  `(setf (get ,name 'filter)
	 (m ,args ,@body)))

; documenting filters

(defun def-filter-documentation (name arglist doc-string &key from-django-p but-different-from-django-because)
  (setf (get name 'filter-documentation)
	(list arglist
	      doc-string
	      :from-django-p
	      from-django-p
	      :but-different-from-django-because
	      but-different-from-django-because)))

; getting filter documentation

(defun get-filter-documentation (keyword)
  (if #1=(get keyword 'filter-documentation)
      (cons keyword #1#)))

; getting a list of all filters

(defun get-all-filters ()
  (let (filters)
    (do-symbols (k :keyword (sort filters 'string< :key 'string))
      (if (get-filter-documentation k)
	(push k filters)))))

; making sure all the variables in an example table are in *TEMPLATE-ARGUMENTS*

(defun .check-example-table-plist (example-table-plist)
  (when example-table-plist
    (destructuring-bind (k v . rest) example-table-plist
      (declare (ignore v))
      (aif (nth-value 1 (get-variable k))
	   (cons it #1=(.check-example-table-plist rest))
	   #1#))))