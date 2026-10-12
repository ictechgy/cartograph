func price(_ quantity: Int) -> Int { quantity * 10 } // oracle: price_int
func price(_ coupon: String) -> Int { coupon.count } // oracle: price_string
func tax(_ amount: Int) -> Int { amount / 10 } // oracle: tax
func subtotal(_ quantity: Int) -> Int { price(quantity) } // oracle: subtotal
