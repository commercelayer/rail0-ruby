# frozen_string_literal: true

module Rail0
  # 1.0.0 is where the PUBLISHED history starts. The gem reached 1.2.0 while it was
  # consumed by path from a sibling checkout, where the number bought nothing: no registry
  # ever served a 1.x, no tag was ever cut, and the one consumer resolves the working tree.
  # Publishing from 1.2.0 would have implied two releases nobody can install.
  VERSION = "1.1.0"
end
