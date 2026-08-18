module Vcardable
    extend ActiveSupport::Concern

    # https://github.com/whomwah/rqrcode/issues/46
    # https://kelsey-pedersen.medium.com/generating-a-vcard-in-rails-app-with-vcardigan-5953f08d1339
    def as_vcard
        vcard = VCardigan.create(:version => "4.0")
        vcard.fullname "Placeholder Name"
        vcard.tel "+16502223333", :type => "mobile"
        vcard.email "hello@placeholder.com" 
        vcard[:item1].URL "https://www.placeholder.com/"
        encoded_string = Base64.strict_encode64(File.open("placeholder-logo.png", "rb").read)
        vcard.photo encoded_string, {:type => "image/png", :"ENCODING" => "b"}
    end
end