use lwk_wollet::elements::encode::Error as EncodeError;
use lwk_wollet::elements::pset::ParseError;

/// Possible errors emitted
#[derive(Debug)]
pub struct LwkError {
    pub msg: String,
}

impl From<lwk_wollet::Error> for LwkError {
    fn from(value: lwk_wollet::Error) -> Self {
        LwkError {
            msg: format!("{:?}", value),
        }
    }
}

impl From<EncodeError> for LwkError {
    fn from(value: EncodeError) -> Self {
        LwkError {
            msg: format!("{:?}", value),
        }
    }
}

impl From<ParseError> for LwkError {
    fn from(value: ParseError) -> Self {
        LwkError {
            msg: format!("{:?}", value),
        }
    }
}

impl From<lwk_wollet::elements::AddressError> for LwkError {
    fn from(value: lwk_wollet::elements::AddressError) -> Self {
        LwkError {
            msg: format!("{:?}", value),
        }
    }
}

impl From<lwk_signer::NewError> for LwkError {
    fn from(value: lwk_signer::NewError) -> Self {
        LwkError {
            msg: format!("{:?}", value),
        }
    }
}

impl From<String> for LwkError {
    fn from(msg: String) -> Self {
        LwkError { msg }
    }
}
