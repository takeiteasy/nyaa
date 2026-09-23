(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The parameter schema: the closed vocabulary, coercion of the arguments a
;;; model supplies, and the JSON Schema rendering both directions.

(defun coerced (schema args)
  (nyaa:coerce-args schema args))

(defun problem (schema args)
  (nth-value 1 (nyaa:coerce-args schema args)))

(defun json (schema)
  (com.inuoe.jzon:stringify (nyaa:schema->json-schema schema)))

(defun same-json (json text)
  "JSON, a rendered schema, against TEXT. Compared structurally: a JSON
object carries no key order."
  (labels ((same (a b)
             (cond
               ((hash-table-p a)
                (and (hash-table-p b)
                     (= (hash-table-count a) (hash-table-count b))
                     (block compare
                       (maphash (lambda (key value)
                                  (multiple-value-bind (other found)
                                      (gethash key b)
                                    (unless (and found (same value other))
                                      (return-from compare nil))))
                                a)
                       t)))
               ((and (vectorp a) (not (stringp a)))
                (and (vectorp b) (not (stringp b)) (= (length a) (length b))
                     (every #'same a b)))
               (t (equal a b)))))
    (same json (com.inuoe.jzon:parse text))))

(defparameter +every-specifier+
  `((:name string :required t :doc "a name")
    (:size (integer 1 100) :doc "how many" :default 10)
    (:ratio number)
    (:loud boolean :default nil)
    (:op (member :read :write) :required t)
    (:note (or null string))
    (:tags (nyaa:array-of string))
    (:headers (nyaa:map-of string))
    (:where (nyaa:object (:city string :required t) (:zip string)))
    (:extra nyaa:any :doc "anything at all")))

;;; --- coercion ---------------------------------------------------------

(test coercion-accepts-strings-symbols-and-keywords
  (is (equal '(:cmd "ls") (coerced '((:cmd string)) '(:cmd "ls"))))
  (is (equal '(:cmd "ls") (coerced '((:cmd string)) '(:cmd :ls))))
  (is (equal '(:n 30000) (coerced '((:n integer)) '(:n "30000"))))
  (is (equal '(:n 1.5d0) (coerced '((:n number)) '(:n "1.5d0"))))
  (is (equal '(:on t) (coerced '((:on boolean)) '(:on "true"))))
  (is (equal '(:on nil) (coerced '((:on boolean)) '(:on "false"))))
  (is (equal '(:op :write) (coerced '((:op (member :read :write))) '(:op "write"))))
  (is (equal '(:op :write) (coerced '((:op (member :read :write))) '(:op :write)))))

(test coercion-rejects-what-will-not-coerce
  (is (search ":cmd" (problem '((:cmd string)) '(:cmd 7))))
  (is (problem '((:n integer)) '(:n "ten")))
  (is (problem '((:n (integer 1 100)) ) '(:n 0)))
  (is (problem '((:n number)) '(:n "1 2")))
  (is (problem '((:on boolean)) '(:on "maybe")))
  (is (problem '((:op (member :read :write))) '(:op "delete"))))

(test required-missing-and-defaults-filled
  (is (search ":cmd" (problem '((:cmd string :required t)) '())))
  (is (equal '(:n 30000) (coerced '((:n integer :default 30000)) '())))
  ;; An explicit value wins over the default, including NIL.
  (is (equal '(:on nil) (coerced '((:on boolean :default t)) '(:on nil))))
  ;; A parameter with neither is simply absent.
  (is (equal '() (coerced '((:note string)) '()))))

(test unknown-parameter-is-rejected
  (is (search ":colour" (problem '((:cmd string)) '(:cmd "ls" :colour t)))))

(test compound-specifiers-coerce-elementwise
  (is (equal '(:tags ("a" "b"))
             (coerced '((:tags (nyaa:array-of string))) '(:tags (:a "b")))))
  (is (problem '((:tags (nyaa:array-of integer))) '(:tags ("x"))))
  (is (equal '(:headers ("x-tag" "abc"))
             (coerced '((:headers (nyaa:map-of string))) '(:headers (:x-tag "abc")))))
  ;; An alist has an even length too; it must not pass as one empty entry.
  (is (problem '((:headers (nyaa:map-of string)))
               '(:headers (("X-Tag" . "a") ("Y" . "b")))))
  (is (equal '(:where (:city "berlin"))
             (coerced '((:where (nyaa:object (:city string :required t))))
                      '(:where (:city "berlin")))))
  (is (problem '((:where (nyaa:object (:city string :required t))))
               '(:where ()))))

(test null-is-allowed-only-where-declared
  (is (equal '(:note nil) (coerced '((:note (or null string))) '(:note nil))))
  (is (equal '(:note "hi") (coerced '((:note (or null string))) '(:note "hi"))))
  (is (problem '((:note string)) '(:note nil))))

(test a-specifier-outside-the-set-is-a-definition-error
  (signals error (nyaa:validate-schema '((:x pathname))))
  (signals error (nyaa:validate-schema '((:x (member "read")))))
  (signals error (nyaa:validate-schema '((:x (or string integer)))))
  (signals error (nyaa:validate-schema '((:x string :colour t))))
  (signals error (nyaa:validate-schema '(("x" string))))
  (is (eq :ok (progn (nyaa:validate-schema +every-specifier+) :ok))))

;;; --- JSON Schema ------------------------------------------------------

(test rendering-produces-a-tools-array-object-schema
  (is (same-json (nyaa:schema->json-schema '((:cmd string :required t :doc "run it")))
                 "{\"type\":\"object\",
                   \"properties\":{\"cmd\":{\"type\":\"string\",\"description\":\"run it\"}},
                   \"required\":[\"cmd\"],
                   \"additionalProperties\":false}")))

(test rendering-covers-every-specifier
  (flet ((rendered (spec)
           (gethash "x" (gethash "properties"
                                 (nyaa:schema->json-schema (list (list :x spec)))))))
    (is (same-json (rendered 'string) "{\"type\":\"string\"}"))
    (is (same-json (rendered '(integer 1)) "{\"type\":\"integer\",\"minimum\":1}"))
    (is (same-json (rendered '(integer 1 100))
                   "{\"type\":\"integer\",\"minimum\":1,\"maximum\":100}"))
    (is (same-json (rendered 'number) "{\"type\":\"number\"}"))
    (is (same-json (rendered 'boolean) "{\"type\":\"boolean\"}"))
    (is (same-json (rendered '(member :read :write))
                   "{\"type\":\"string\",\"enum\":[\"read\",\"write\"]}"))
    (is (same-json (rendered '(or null string)) "{\"type\":[\"string\",\"null\"]}"))
    (is (same-json (rendered '(nyaa:array-of string))
                   "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}"))
    (is (same-json (rendered '(nyaa:map-of string))
                   "{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}}"))
    (is (same-json (rendered '(nyaa:object (:city string :required t)))
                   "{\"type\":\"object\",
                     \"properties\":{\"city\":{\"type\":\"string\"}},
                     \"required\":[\"city\"],
                     \"additionalProperties\":false}"))
    (is (same-json (rendered 'nyaa:any) "{}"))))

(test rendering-keeps-declaration-order
  "Property order follows declaration, not alphabetical or hash order --
SBCL's hash tables iterate in insertion order, so a rendered schema renders
the same way on every run."
  (is (string= (json '((:zeta string :doc "last letter" :default "z")
                        (:alpha (nyaa:object (:yak integer :required t) (:bee boolean)))
                        (:mid (integer 1 9))))
               "{\"type\":\"object\",\"properties\":{\"zeta\":{\"type\":\"string\",\"description\":\"last letter\",\"default\":\"z\"},\"alpha\":{\"type\":\"object\",\"properties\":{\"yak\":{\"type\":\"integer\"},\"bee\":{\"type\":\"boolean\"}},\"required\":[\"yak\"],\"additionalProperties\":false},\"mid\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":9}},\"required\":[],\"additionalProperties\":false}")))

(test any-coerces-whatever-it-is-given
  (is (equal '(:x 7) (coerced '((:x nyaa:any)) '(:x 7))))
  (is (equal '(:x "s") (coerced '((:x nyaa:any)) '(:x "s"))))
  (is (equal '(:x (:a 1)) (coerced '((:x nyaa:any)) '(:x (:a 1))))))

(defun sorted-schema (schema)
  "SCHEMA by parameter name: a JSON object carries no order to preserve."
  (sort (copy-list schema) #'string< :key #'first))

(test a-schema-survives-a-round-trip-through-json
  (let ((back (nyaa:json-schema->schema
               (com.inuoe.jzon:parse (json +every-specifier+)))))
    (is (equal (sorted-schema +every-specifier+) (sorted-schema back)))))

(test json-schema-survives-a-round-trip-through-a-schema
  (let ((source (json +every-specifier+)))
    (is (same-json (nyaa:schema->json-schema
                    (nyaa:json-schema->schema (com.inuoe.jzon:parse source)))
                   source))))

(test importing-an-unknown-construct-is-an-error
  (signals error (nyaa:json-schema->schema
                  (com.inuoe.jzon:parse "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"date\"}}}")))
  (signals error (nyaa:json-schema->schema
                  (com.inuoe.jzon:parse "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"array\"}}}")))
  (signals error (nyaa:json-schema->schema (com.inuoe.jzon:parse "{\"type\":\"string\"}"))))
