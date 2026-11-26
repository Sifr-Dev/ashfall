class User < ApplicationRecord
  has_many :notes, dependent: :restrict_with_exception
end
