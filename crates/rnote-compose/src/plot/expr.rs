//! A small parser and evaluator for real functions of `x`, e.g. `2x^2 - 3x + 1`, `ln(x)` or `log(2, x)`.
//!
//! Grammar, from lowest to highest precedence:
//!
//! ```text
//! expr    := term (("+" | "-") term)*
//! term    := unary (("*" | "/") unary | implicit unary)*
//! unary   := ("+" | "-") unary | power
//! power   := atom ("^" unary)?
//! atom    := number | "x" | constant | function "(" expr ("," expr)? ")" | "(" expr ")"
//! ```
//!
//! Implicit multiplication allows `2x`, `3(x + 1)` or `x sin(x)`.

// Imports
use std::fmt;

/// An error while parsing an expression, with the character position it occurred at.
#[derive(Debug, Clone, PartialEq)]
pub struct ParseError {
    /// Character position in the input.
    pub pos: usize,
    /// What went wrong.
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} (at position {})", self.message, self.pos + 1)
    }
}

impl std::error::Error for ParseError {}

/// A function taking one argument.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Func {
    Sqrt,
    Cbrt,
    Abs,
    Exp,
    Ln,
    Log10,
    Log2,
    Sin,
    Cos,
    Tan,
    Asin,
    Acos,
    Atan,
    Floor,
    Ceil,
    Sign,
}

impl Func {
    fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "sqrt" | "raiz" => Self::Sqrt,
            "cbrt" => Self::Cbrt,
            "abs" => Self::Abs,
            "exp" => Self::Exp,
            "ln" => Self::Ln,
            "log" | "log10" => Self::Log10,
            "log2" => Self::Log2,
            "sin" | "sen" => Self::Sin,
            "cos" => Self::Cos,
            "tan" | "tg" => Self::Tan,
            "asin" | "arcsin" | "asen" | "arcsen" => Self::Asin,
            "acos" | "arccos" => Self::Acos,
            "atan" | "arctan" | "arctg" => Self::Atan,
            "floor" => Self::Floor,
            "ceil" => Self::Ceil,
            "sign" | "sgn" => Self::Sign,
            _ => return None,
        })
    }

    fn apply(self, v: f64) -> f64 {
        match self {
            Self::Sqrt => v.sqrt(),
            Self::Cbrt => v.cbrt(),
            Self::Abs => v.abs(),
            Self::Exp => v.exp(),
            Self::Ln => v.ln(),
            Self::Log10 => v.log10(),
            Self::Log2 => v.log2(),
            Self::Sin => v.sin(),
            Self::Cos => v.cos(),
            Self::Tan => v.tan(),
            Self::Asin => v.asin(),
            Self::Acos => v.acos(),
            Self::Atan => v.atan(),
            Self::Floor => v.floor(),
            Self::Ceil => v.ceil(),
            Self::Sign => {
                if v == 0.0 {
                    0.0
                } else {
                    v.signum()
                }
            }
        }
    }
}

/// Node of the expression tree.
#[derive(Debug, Clone, PartialEq)]
enum Node {
    /// A number.
    Num(f64),
    /// The variable `x`.
    X,
    /// Negation.
    Neg(Box<Node>),
    /// Addition.
    Add(Box<Node>, Box<Node>),
    /// Subtraction.
    Sub(Box<Node>, Box<Node>),
    /// Multiplication.
    Mul(Box<Node>, Box<Node>),
    /// Division.
    Div(Box<Node>, Box<Node>),
    /// Power.
    Pow(Box<Node>, Box<Node>),
    /// A function of one argument.
    Call(Func, Box<Node>),
    /// Logarithm with a base: `log(base, value)`.
    LogBase(Box<Node>, Box<Node>),
}

/// A parsed real function of the variable `x`.
#[derive(Debug, Clone, PartialEq)]
pub struct Expr(Node);

impl Expr {
    /// Parses an expression. A leading `y =` or `f(x) =` is ignored.
    pub fn parse(input: &str) -> Result<Self, ParseError> {
        let (offset, body) = match input.find('=') {
            Some(idx) => (idx + 1, &input[idx + 1..]),
            None => (0, input),
        };
        let mut parser = Parser {
            chars: body.chars().collect(),
            pos: 0,
            offset,
        };
        let root = parser.expr()?;
        parser.skip_ws();
        match parser.peek() {
            Some(',') => Err(parser.error("unexpected ',' - use '.' for decimals")),
            Some(c) => Err(parser.error(format!("unexpected '{c}'"))),
            None => Ok(Self(root)),
        }
    }

    /// Evaluates the expression at `x`. Undefined values result in NaN or infinities.
    pub fn eval(&self, x: f64) -> f64 {
        self.0.eval(x)
    }
}

impl Node {
    fn eval(&self, x: f64) -> f64 {
        match self {
            Self::Num(v) => *v,
            Self::X => x,
            Self::Neg(a) => -a.eval(x),
            Self::Add(a, b) => a.eval(x) + b.eval(x),
            Self::Sub(a, b) => a.eval(x) - b.eval(x),
            Self::Mul(a, b) => a.eval(x) * b.eval(x),
            Self::Div(a, b) => a.eval(x) / b.eval(x),
            Self::Pow(a, b) => pow(a.eval(x), b.eval(x)),
            Self::Call(f, a) => f.apply(a.eval(x)),
            Self::LogBase(base, a) => a.eval(x).ln() / base.eval(x).ln(),
        }
    }
}

/// Power that is also defined for negative bases with odd root exponents, e.g. `x^(1/3)`.
fn pow(base: f64, exp: f64) -> f64 {
    if base < 0.0 && exp.fract() != 0.0 {
        let recip = 1.0 / exp;
        if (recip - recip.round()).abs() < 1e-9 && (recip.round() as i64) % 2 != 0 {
            return -(-base).powf(exp);
        }
    }
    base.powf(exp)
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
    /// Offset of the parsed body in the original input, for error positions.
    offset: usize,
}

impl Parser {
    fn error(&self, message: impl Into<String>) -> ParseError {
        ParseError {
            pos: self.offset + self.pos,
            message: message.into(),
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.pos += 1;
        }
    }

    /// Consumes the char if it is next, after whitespace.
    fn eat(&mut self, c: char) -> bool {
        self.skip_ws();
        if self.peek() == Some(c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, c: char) -> Result<(), ParseError> {
        if self.eat(c) {
            Ok(())
        } else {
            Err(self.error(format!("expected '{c}'")))
        }
    }

    fn expr(&mut self) -> Result<Node, ParseError> {
        let mut lhs = self.term()?;
        loop {
            if self.eat('+') {
                lhs = Node::Add(Box::new(lhs), Box::new(self.term()?));
            } else if self.eat('-') {
                lhs = Node::Sub(Box::new(lhs), Box::new(self.term()?));
            } else {
                return Ok(lhs);
            }
        }
    }

    fn term(&mut self) -> Result<Node, ParseError> {
        let mut lhs = self.unary()?;
        loop {
            if self.eat('*') {
                lhs = Node::Mul(Box::new(lhs), Box::new(self.unary()?));
            } else if self.eat('/') {
                lhs = Node::Div(Box::new(lhs), Box::new(self.unary()?));
            } else if self.starts_atom() {
                lhs = Node::Mul(Box::new(lhs), Box::new(self.power()?));
            } else {
                return Ok(lhs);
            }
        }
    }

    /// Whether an atom follows, which means implicit multiplication.
    fn starts_atom(&mut self) -> bool {
        self.skip_ws();
        self.peek()
            .is_some_and(|c| c.is_ascii_alphanumeric() || c == '(' || c == '.' || c == 'π')
    }

    fn unary(&mut self) -> Result<Node, ParseError> {
        if self.eat('-') {
            Ok(Node::Neg(Box::new(self.unary()?)))
        } else if self.eat('+') {
            self.unary()
        } else {
            self.power()
        }
    }

    fn power(&mut self) -> Result<Node, ParseError> {
        let base = self.atom()?;
        if self.eat('^') {
            Ok(Node::Pow(Box::new(base), Box::new(self.unary()?)))
        } else {
            Ok(base)
        }
    }

    fn atom(&mut self) -> Result<Node, ParseError> {
        self.skip_ws();
        match self.peek() {
            Some('(') => {
                self.pos += 1;
                let inner = self.expr()?;
                self.expect(')')?;
                Ok(inner)
            }
            Some(c) if c.is_ascii_digit() || c == '.' => self.number(),
            Some('π') => {
                self.pos += 1;
                Ok(Node::Num(std::f64::consts::PI))
            }
            Some(c) if c.is_ascii_alphabetic() => self.identifier(),
            Some(',') => Err(self.error("unexpected ',' - use '.' for decimals")),
            Some(c) => Err(self.error(format!("unexpected '{c}'"))),
            None => Err(self.error("unexpected end of the expression")),
        }
    }

    fn number(&mut self) -> Result<Node, ParseError> {
        let start = self.pos;
        while self.peek().is_some_and(|c| c.is_ascii_digit() || c == '.') {
            self.pos += 1;
        }
        let text = self.chars[start..self.pos].iter().collect::<String>();
        text.parse::<f64>().map(Node::Num).map_err(|_| ParseError {
            pos: self.offset + start,
            message: format!("invalid number '{text}'"),
        })
    }

    fn identifier(&mut self) -> Result<Node, ParseError> {
        let start = self.pos;
        while self.peek().is_some_and(|c| c.is_ascii_alphanumeric()) {
            self.pos += 1;
        }
        let name = self.chars[start..self.pos]
            .iter()
            .collect::<String>()
            .to_lowercase();

        if let Some(expr) = self.known_identifier(&name)? {
            return Ok(expr);
        }

        // implicit multiplication of single letter names, e.g. `xsin(x)` or `pix`
        self.pos = start;
        for prefix in ["pi", "x", "e"] {
            if name.starts_with(prefix) && name.len() > prefix.len() {
                self.pos = start + prefix.len();
                return Ok(self.known_identifier(prefix)?.unwrap());
            }
        }
        Err(ParseError {
            pos: self.offset + start,
            message: format!("unknown name '{name}'"),
        })
    }

    fn known_identifier(&mut self, name: &str) -> Result<Option<Node>, ParseError> {
        Ok(Some(match name {
            "x" => Node::X,
            "pi" => Node::Num(std::f64::consts::PI),
            "e" => Node::Num(std::f64::consts::E),
            "log" => {
                self.expect('(')?;
                let first = self.expr()?;
                if self.eat(',') {
                    let value = self.expr()?;
                    self.expect(')')?;
                    Node::LogBase(Box::new(first), Box::new(value))
                } else {
                    self.expect(')')?;
                    Node::Call(Func::Log10, Box::new(first))
                }
            }
            _ => match Func::from_name(name) {
                Some(func) => {
                    // allow `sin x` without parentheses for a single atom
                    let arg = if self.eat('(') {
                        let arg = self.expr()?;
                        self.expect(')')?;
                        arg
                    } else {
                        self.power()?
                    };
                    Node::Call(func, Box::new(arg))
                }
                None => return Ok(None),
            },
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eval(input: &str, x: f64) -> f64 {
        Expr::parse(input).unwrap().eval(x)
    }

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn polynomials() {
        assert!(approx(eval("2x + 1", 3.0), 7.0));
        assert!(approx(eval("x^2 - 3x + 2", 1.0), 0.0));
        assert!(approx(eval("-x^2", 3.0), -9.0));
        assert!(approx(eval("x^3 - 2x^2 + x - 5", 2.0), -3.0));
        assert!(approx(eval("3(x + 1)(x - 1)", 2.0), 9.0));
        assert!(approx(eval("2^-1", 0.0), 0.5));
        assert!(approx(eval("2^3^2", 0.0), 512.0));
    }

    #[test]
    fn prefixes_are_ignored() {
        assert!(approx(eval("y = 2x", 2.0), 4.0));
        assert!(approx(eval("f(x) = x^2", 3.0), 9.0));
    }

    #[test]
    fn logarithms() {
        assert!(approx(eval("ln(e)", 0.0), 1.0));
        assert!(approx(eval("log(100)", 0.0), 2.0));
        assert!(approx(eval("log(2, 8)", 0.0), 3.0));
        assert!(approx(eval("log2(x)", 16.0), 4.0));
        assert!(eval("ln(x)", -1.0).is_nan());
    }

    #[test]
    fn functions_and_constants() {
        assert!(approx(eval("sin(pi/2)", 0.0), 1.0));
        assert!(approx(eval("sen(x)", 0.0), 0.0));
        assert!(approx(eval("sqrt(x)", 9.0), 3.0));
        assert!(approx(eval("abs(x)", -2.0), 2.0));
        assert!(approx(eval("2sin(x)", std::f64::consts::FRAC_PI_2), 2.0));
        assert!(approx(
            eval("xsin(x)", std::f64::consts::FRAC_PI_2),
            std::f64::consts::FRAC_PI_2
        ));
        assert!(approx(eval("2pi", 0.0), std::f64::consts::TAU));
    }

    #[test]
    fn odd_roots_of_negative_numbers() {
        assert!(approx(eval("x^(1/3)", -8.0), -2.0));
        assert!(eval("x^(1/2)", -4.0).is_nan());
    }

    #[test]
    fn errors_have_positions() {
        let err = Expr::parse("2x + * 3").unwrap_err();
        assert_eq!(err.pos, 5);
        assert!(Expr::parse("foo(x)").is_err());
        assert!(Expr::parse("(x + 1").is_err());
        assert!(Expr::parse("0,5x").unwrap_err().message.contains("'.'"));
    }
}
