(set-logic QF_BV)
(declare-fun x () (_ BitVec 32))
(declare-fun y () (_ BitVec 16))
(declare-fun z () (_ BitVec 20))
(assert
  (let ((c1 (= x ((_ sign_extend 12) z))))
    (let ((c2 (= y ((_ extract 18 3) x))))
      (let ((c3
              (bvslt (concat z (_ bv5 12))
                     (bvand (bvor (bvxor (bvnot x) ((_ zero_extend 28) #b1111))
                                  (concat #xAF02 y))
                            (concat (bvmul ((_ extract 31 16) x) y)
                                    (bvashr (_ bv42 16) #x0001))))))
        (and c1 (xor c2 c3))))))
(check-sat)
(exit)
