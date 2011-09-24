#lang racket/base

(require
 scheme/match
 "private/syntax/ast-core.ss"
 "private/syntax/ast-utils.ss"
 )

(define (optimize-declaration decl)
  (match decl
    [(struct FunctionDeclaration (loc name args body))
     (FunctionDeclaration loc name args (map optimize body))]
    [(struct LetDeclaration (loc bindings))
     (LetDeclaration loc (map optimize-variable-initializer bindings))]
    [(struct VariableDeclaration (loc bindings))
     (VariableDeclaration loc (map optimize-variable-initializer bindings))]
    [_ (error 'optimize-declaration "~S not matched" decl)]))

(define (optimize-variable-initializer init)
  (match init
    [(struct VariableInitializer (loc id init))
     (VariableInitializer loc id (and init (optimize-expression init)))]
    [_ (error 'optimize-variable-initializer "~S not matched" init)]))

(define (optimize-statement stmt)
  (match stmt
    [(struct BlockStatement (loc statements))
     (let ([l (map optimize-statement statements)])
       (if (= 1 (length l)) (car l) (BlockStatement loc l)))]
    [(struct EmptyStatement _) stmt]
    [(struct ExpressionStatement (loc expression))
     (ExpressionStatement loc (optimize-expression expression))]
    [(struct IfStatement (loc test consequent alternate))
     (let ([expr (optimize-expression test)]
           [stmt (optimize-statement consequent)])
       (if (and (not alternate)
                (expression-side-effects-free? expr)
                (ExpressionStatement? stmt)
                (expression-side-effects-free? (ExpressionStatement-expression stmt)))
           (EmptyStatement loc)
           (IfStatement loc expr stmt
                        (and alternate
                             (let ([s (optimize-statement alternate)])
                               (match s
                                 [(struct ExpressionStatement (_ (and (? expression-side-effects-free?))))
                                  #f]
                                 [_ s]))))))]
    [(struct DoWhileStatement (loc body test))
     (DoWhileStatement loc (optimize-statement body) (optimize-expression test))]
    [(struct WhileStatement (loc test body))
     (WhileStatement loc (optimize-expression test) (optimize-statement body))]
    [(struct ForStatement (loc init test incr body))
     (ForStatement loc
                   (match init
                     [(struct VariableDeclaration (loc bindings)) (VariableDeclaration loc (map optimize-variable-initializer bindings))]
                     [(struct LetDeclaration (loc bindings)) (LetDeclaration loc (map optimize-variable-initializer bindings))]
                     [_ (and init (optimize-expression init))])
                   (and test (optimize-expression test))
                   (and incr (optimize-expression incr))
                   (optimize-statement body))]
    [(struct ForInStatement (loc lhs container body))
     (ForInStatement loc
                     (match lhs
                       [(struct VariableDeclaration (loc bindings)) (VariableDeclaration loc (map optimize-variable-initializer bindings))]
                       [(struct LetDeclaration (loc bindings)) (LetDeclaration loc (map optimize-variable-initializer bindings))]
                       [_ (optimize-expression lhs)])
                     (optimize-expression container)
                     (optimize-statement body))]
    [(struct ContinueStatement (loc label))
     stmt]
    [(struct BreakStatement (loc label))
     stmt]
    [(struct ReturnStatement (loc value))
     (match value
       [(struct CallExpression [_ (struct FunctionExpression [loc _ '() statements]) '()])
        ;; This tranformation is not valid in general, but it should be valid for code
        ;; generated by Sines; the problem for the general case is that the statements'
        ;; final statement might not be a return statement
        (optimize-statement (BlockStatement loc statements))]
       [_ (ReturnStatement loc (and value (optimize-expression value)))])]
    [(struct LetStatement (loc bindings body))
     (LetStatement loc (map optimize-variable-initializer bindings) (optimize-statement body))]
    [(struct WithStatement (loc context body))
     (WithStatement loc (optimize-expression context) (optimize-statement body))]
    [(struct SwitchStatement (loc expression cases))
     (SwitchStatement loc (optimize-expression expression)
                      (map (lambda (clause)
                             (match clause
                               [(struct CaseClause (loc question answer))
                                (CaseClause loc (and question (and question (optimize-expression question))) (map optimize-statement answer))]))
                           cases))]
    [(struct LabelledStatement (loc label statement))
     (LabelledStatement loc label (optimize-statement statement))]
    [(struct ThrowStatement (loc value))
     (ThrowStatement loc (optimize-expression value))]
    [(struct TryStatement (loc body catches finally))
     (TryStatement loc (optimize-statement body)
                   (map (lambda (catch)
                          (match catch
                            [(struct CatchClause (loc id body))
                             (CatchClause loc id (optimize-statement body))]))
                        catches)
                   (and finally (optimize-statement finally)))]
    [_ (if (Declaration? stmt)
           (optimize-declaration stmt)
           (error 'optimize-statement "~S not matched" stmt))]))

(define (optimize-expression expr)
  (match expr
    [(struct StringLiteral _)  expr]
    [(struct NumericLiteral _) expr]
    [(struct BooleanLiteral _) expr]
    [(struct NullLiteral _)    expr]
    [(struct RegexpLiteral _)  expr]
    [(struct ArrayLiteral (loc elements))
     (ArrayLiteral loc (map (lambda (e) (and e (optimize-expression e))) elements))]
    [(struct ObjectLiteral (loc properties))
     (ObjectLiteral loc (map (lambda (pair) (cons (car pair) (optimize-expression (cdr pair)))) properties))]
    [(struct ThisReference _) expr]
    [(struct VarReference _)  expr]
    [(struct BracketReference (loc container key))
     (BracketReference loc (optimize-expression container) (optimize-expression key))]
    [(struct DotReference (loc container id))
     (DotReference loc (optimize-expression container) id)]
    [(struct NewExpression (loc constructor arguments))
     (NewExpression loc (optimize-expression constructor) (map optimize-expression arguments))]
    [(struct PostfixExpression (loc expression operator))
     (PostfixExpression loc (optimize-expression expression) operator)]
    [(struct PrefixExpression (loc operator expression))
     (PrefixExpression loc operator (optimize-expression expression))]
    [(struct InfixExpression (loc left operator right))
     (let ([le (optimize-expression left)]
           [re (optimize-expression right)])
       (case operator
         [(!==)
          (cond [(and (BooleanLiteral? re) (not (BooleanLiteral-value re)) (expression-boolean? le))
                 le]
                [else (InfixExpression loc le operator re)])]
         [(-)
          (cond [(and (NumericLiteral? le) (zero? (NumericLiteral-value le)))
                 (PrefixExpression loc '- re)]
                [else (InfixExpression loc le operator re)])]
         [else (InfixExpression loc le operator re)]))]
    [(struct ConditionalExpression (loc test consequent alternate))
     (ConditionalExpression loc (optimize-expression test) (optimize-expression consequent) (optimize-expression alternate))]
    [(struct AssignmentExpression (loc lhs operator rhs))
     (AssignmentExpression loc (optimize-expression lhs) operator (optimize-expression rhs))]
    [(struct FunctionExpression (loc name args body))
     (FunctionExpression loc name args (map optimize body))]
    [(struct LetExpression (loc bindings body))
     (LetExpression loc (map optimize-variable-initializer bindings) (optimize-expression body))]
    [(struct CallExpression (loc method args))
     (CallExpression loc (optimize-expression method) (map optimize-expression args))]
    [(struct ParenExpression (loc expr))
     (ParenExpression loc (optimize-expression expr))]
    [(struct ListExpression (loc exprs))
     (ListExpression loc (map optimize-expression exprs))]
    [_ (error 'optimize-expression "~S not matched" expr)]))

(define (expression-side-effects-free? expr)
  (or (StringLiteral? expr)
      (RegexpLiteral? expr)
      (NumericLiteral? expr)
      (BooleanLiteral? expr)
      (NullLiteral? expr)
      (and (ArrayLiteral? expr) (andmap (lambda (e) (or (not e) (expression-side-effects-free? e))) (ArrayLiteral-elements expr)))
      (and (ObjectLiteral? expr) (andmap (lambda (e) (expression-side-effects-free? (cdr e))) (ObjectLiteral-properties expr)))
      (ThisReference? expr)
      (VarReference? expr)
      (and (BracketReference? expr) (expression-side-effects-free? (BracketReference-container expr)) (expression-side-effects-free? (BracketReference-key expr)))
      (and (DotReference? expr) (expression-side-effects-free? (DotReference-container expr)))
      (and (InfixExpression? expr) (expression-side-effects-free? (InfixExpression-left expr)) (expression-side-effects-free? (InfixExpression-right expr))
           (memq (InfixExpression-operator expr) '(!= == !== === < > <= >=)) )
      ;; TODO: more expressions
      ))

(define (expression-boolean? expr)
  (or (BooleanLiteral? expr)
      (and (InfixExpression? expr) (memq (InfixExpression-operator expr) '(!= == !== === < > <= >=)))))

(define (optimize term)
  (cond [(Declaration? term)  (optimize-declaration term)]
        [(Statement/X? term)  (optimize-statement term)]
        [(Expression/X? term) (optimize-expression term)]
        [else (error 'optimize "~S not matched" term)]))

(provide optimize)